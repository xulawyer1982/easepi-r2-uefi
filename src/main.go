// fxrecovery — RK3588 网页刷机服务
//
// 运行在 rescue 固件的 initramfs 里：枚举本机磁盘，通过浏览器把
// 用户上传的系统镜像原样写入 NVMe / SATA / USB 盘。
//
// 设计约束：
//  1. 单文件静态二进制（CGO_ENABLED=0），不依赖任何外部库
//  2. 只写"整盘"，且绝不写自己正在运行的那块盘
//  3. 边写边算 sha256，写完后回读比对，失败即明确报错
//  4. 镜像先落地到 /images（tmpfs 或挂载的 vfat），不占内存两次
package main

import (
	"compress/gzip"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

//go:embed www/index.html
var wwwFS embed.FS

const (
	imageDir   = "/images"
	version    = "1.0.0"
	maxUploadB = int64(32) << 30 // 单文件上限 32 GiB
)

// ---------------------------------------------------------------- 数据模型 --

type Disk struct {
	Name      string   `json:"name"`
	Path      string   `json:"path"`
	Size      uint64   `json:"size"`
	Model     string   `json:"model"`
	Bus       string   `json:"bus"`
	Mounted   []string `json:"mounted"`
	IsBoot    bool     `json:"is_boot"`
	Removable bool     `json:"removable"`
	Writable  bool     `json:"writable"`
}

type ImageInfo struct {
	Name    string `json:"name"`
	Path    string `json:"path"`
	Size    uint64 `json:"size"`
	ModTime int64  `json:"mod_time"`
	Kind    string `json:"kind"` // raw | gz | xz | unknown
}

type Status struct {
	Running  bool    `json:"running"`
	Phase    string  `json:"phase"` // idle|preparing|writing|verifying|done|error|cancelled
	Image    string  `json:"image"`
	Target   string  `json:"target"`
	Total    uint64  `json:"total"`
	Done     uint64  `json:"done"`
	Speed    float64 `json:"speed"`
	ETA      int     `json:"eta"`
	Message  string  `json:"message"`
	Err      string  `json:"err"`
	Hash     string  `json:"hash"`
	Started  int64   `json:"started"`
	Finished int64   `json:"finished"`
}

var (
	mu       sync.Mutex
	status   = Status{Phase: "idle"}
	cancelCh chan struct{}
	started  time.Time
	lastByte uint64
	lastTime time.Time
)

// ------------------------------------------------------------------ 工具 --

func readTrim(p string, n int) string {
	b, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	s := strings.TrimSpace(string(b))
	if len(s) > n {
		s = s[:n]
	}
	return s
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

// 某块设备及其所有分区的挂载点
func mountsOf(disk string) []string {
	var out []string
	b, err := os.ReadFile("/proc/mounts")
	if err != nil {
		return out
	}
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		dev := f[0]
		// /dev/mmcblk0p1 / /dev/sda1 / /dev/nvme0n1p1 都属于 disk
		if dev == disk || strings.HasPrefix(dev, disk+"p") || strings.HasPrefix(dev, disk+"1") ||
			(strings.HasPrefix(dev, disk) && !isLetter(dev[len(disk):])) {
			out = append(out, f[1])
		}
	}
	return out
}

func isLetter(s string) bool {
	if s == "" {
		return false
	}
	c := s[0]
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

// 启动介质（rescue 自己所在的盘）
// 优先读 cmdline 的 fxboot=，其次读 init 探测后写下的 /run/fxboot
func bootDisk() string {
	if b, err := os.ReadFile("/run/fxboot"); err == nil {
		if s := strings.TrimSpace(string(b)); s != "" {
			return diskOf(s)
		}
	}
	b, _ := os.ReadFile("/proc/cmdline")
	for _, f := range strings.Fields(string(b)) {
		if strings.HasPrefix(f, "fxboot=") {
			d := strings.TrimPrefix(f, "fxboot=")
			return diskOf(d)
		}
	}
	// 退化：找一个挂在 /bootmnt 或 /mnt 的分区
	b, _ = os.ReadFile("/proc/mounts")
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) >= 2 && (f[1] == "/bootmnt" || f[1] == "/mnt") {
			return diskOf(f[0])
		}
	}
	return "/dev/mmcblk0"
}

// /dev/mmcblk0p1 -> /dev/mmcblk0 ; /dev/nvme0n1p2 -> /dev/nvme0n1 ; /dev/sda1 -> /dev/sda
func diskOf(part string) string {
	base := filepath.Base(part)
	if base == "" {
		return part
	}
	dir := filepath.Dir(part)
	// mmcblk / nvme: 去掉 pN
	if i := strings.LastIndex(base, "p"); i > 0 {
		head, tail := base[:i], base[i+1:]
		if _, err := strconv.Atoi(tail); err == nil && (strings.HasPrefix(head, "mmcblk") || strings.HasPrefix(head, "nvme") || strings.HasPrefix(head, "loop")) {
			return filepath.Join(dir, head)
		}
	}
	// sdX / vdX / hdX: 去掉末尾数字
	j := len(base)
	for j > 0 && base[j-1] >= '0' && base[j-1] <= '9' {
		j--
	}
	if j > 0 && j < len(base) {
		return filepath.Join(dir, base[:j])
	}
	return part
}

func devSizeBytes(name string) uint64 {
	s := readTrim("/sys/class/block/"+name+"/size", 32)
	if s == "" {
		return 0
	}
	n, err := strconv.ParseUint(s, 10, 64)
	if err != nil {
		return 0
	}
	return n * 512
}

func diskBus(name string) string {
	switch {
	case strings.HasPrefix(name, "nvme"):
		return "NVMe"
	case strings.HasPrefix(name, "mmcblk"):
		if v := readTrim("/sys/class/block/"+name+"/device/type", 16); v != "" {
			return strings.ToUpper(v) // MMC / SD
		}
		return "MMC"
	case strings.HasPrefix(name, "sd"):
		// USB 盘的 removable 通常为 1
		if readTrim("/sys/class/block/"+name+"/removable", 4) == "1" {
			return "USB"
		}
		return "SATA"
	case strings.HasPrefix(name, "vd"):
		return "VirtIO"
	}
	return "其他"
}

func listDisks() []Disk {
	ents, err := os.ReadDir("/sys/block")
	if err != nil {
		return []Disk{}
	}
	boot := bootDisk()
	out := []Disk{}
	for _, e := range ents {
		name := e.Name()
		switch {
		case strings.HasPrefix(name, "loop"), strings.HasPrefix(name, "ram"),
			strings.HasPrefix(name, "zram"), strings.HasPrefix(name, "sr"),
			strings.HasPrefix(name, "dm-"), strings.HasPrefix(name, "md"):
			continue
		}
		size := devSizeBytes(name)
		if size < 256<<20 { // 小于 256MB 的不作为目标
			continue
		}
		d := Disk{
			Name:      name,
			Path:      "/dev/" + name,
			Size:      size,
			Model:     readTrim("/sys/class/block/"+name+"/device/model", 64),
			Bus:       diskBus(name),
			Mounted:   mountsOf("/dev/" + name),
			IsBoot:    ("/dev/" + name) == boot,
			Removable: readTrim("/sys/class/block/"+name+"/removable", 4) == "1",
		}
		d.Writable = !d.IsBoot && len(d.Mounted) == 0
		out = append(out, d)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func listImages() []ImageInfo {
	out := []ImageInfo{}
	seen := map[string]bool{}
	dirs := []string{imageDir, "/data", "/mnt"}
	for _, dir := range dirs {
		ents, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range ents {
			if e.IsDir() {
				continue
			}
			name := e.Name()
			if strings.HasSuffix(name, ".part") {
				continue
			}
			info, err := e.Info()
			if err != nil || info.Size() < 1<<20 {
				continue
			}
			p := filepath.Join(dir, name)
			if seen[p] {
				continue
			}
			seen[p] = true
			kind := "raw"
			switch {
			case strings.HasSuffix(name, ".gz"):
				kind = "gz"
			case strings.HasSuffix(name, ".xz"):
				kind = "xz"
			case strings.HasSuffix(name, ".img"), strings.HasSuffix(name, ".iso"), strings.HasSuffix(name, ".bin"):
				kind = "raw"
			}
			out = append(out, ImageInfo{Name: name, Path: p, Size: uint64(info.Size()), ModTime: info.ModTime().Unix(), Kind: kind})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ModTime > out[j].ModTime })
	return out
}

func sysInfo() map[string]any {
	urls := []string{}
	ifaces, _ := net.Interfaces()
	for _, i := range ifaces {
		if i.Flags&net.FlagLoopback != 0 || i.Flags&net.FlagUp == 0 {
			continue
		}
		addrs, _ := i.Addrs()
		for _, a := range addrs {
			if ipn, ok := a.(*net.IPNet); ok && ipn.IP.To4() != nil {
				urls = append(urls, "http://"+ipn.IP.String()+"/")
			}
		}
	}
	b, _ := os.ReadFile("/proc/cmdline")
	return map[string]any{
		"version": version,
		"kernel":  readTrim("/proc/version", 200),
		"hostname": func() string { h, _ := os.Hostname(); return h }(),
		"urls":    urls,
		"cmdline": strings.TrimSpace(string(b)),
		"uptime":  readTrim("/proc/uptime", 32),
		"image_dir": imageDir,
	}
}

// ------------------------------------------------------------- 写入引擎 --

type countWriter struct {
	w     io.Writer
	n     *uint64
	h     hash.Hash
	total uint64
	cxl   <-chan struct{}
	err   error
}

func (c *countWriter) Write(p []byte) (int, error) {
	select {
	case <-c.cxl:
		c.err = fmt.Errorf("已取消")
		return 0, c.err
	default:
	}
	n, err := c.w.Write(p)
	if n > 0 {
		atomic.AddUint64(c.n, uint64(n))
		if c.h != nil {
			c.h.Write(p[:n])
		}
	}
	return n, err
}

func setStatus(f func(*Status)) {
	mu.Lock()
	f(&status)
	mu.Unlock()
}

func humanBytes(b uint64) string {
	const u = 1024
	if b < u {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := uint64(u), 0
	for n := b / u; n >= u && exp < 5; n /= u {
		div *= u
		exp++
	}
	return fmt.Sprintf("%.2f %ciB", float64(b)/float64(div), "KMGTPE"[exp])
}

func openImage(path string) (io.ReadCloser, uint64, string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, 0, "", err
	}
	st, _ := f.Stat()
	total := uint64(0)
	if st != nil {
		total = uint64(st.Size())
	}
	switch {
	case strings.HasSuffix(path, ".gz"):
		gz, err := gzip.NewReader(f)
		if err != nil {
			f.Close()
			return nil, 0, "", fmt.Errorf("gzip 头损坏: %w", err)
		}
		// gzip 尾部 4 字节是原始长度（mod 2^32），用于进度估算
		if st != nil && st.Size() > 4 {
			buf := make([]byte, 4)
			if _, e := f.ReadAt(buf, st.Size()-4); e == nil {
				sz := uint64(buf[0]) | uint64(buf[1])<<8 | uint64(buf[2])<<16 | uint64(buf[3])<<24
				if sz > 0 {
					total = sz
				}
			}
		}
		return struct {
			io.Reader
			io.Closer
		}{gz, f}, total, "gz", nil
	case strings.HasSuffix(path, ".xz"):
		if _, err := exec.LookPath("xz"); err != nil {
			f.Close()
			return nil, 0, "", fmt.Errorf("设备上没有 xz 解压器，请改用 .gz 或未压缩镜像")
		}
		cmd := exec.Command("xz", "-dc", path)
		cmd.Stderr = os.Stderr
		out, err := cmd.StdoutPipe()
		if err != nil {
			f.Close()
			return nil, 0, "", err
		}
		if err := cmd.Start(); err != nil {
			f.Close()
			return nil, 0, "", err
		}
		f.Close()
		return out, 0, "xz", nil
	}
	return f, total, "raw", nil
}

func runFlash(image, target string, verify bool) {
	defer func() {
		mu.Lock()
		status.Running = false
		if status.Finished == 0 {
			status.Finished = time.Now().Unix()
		}
		mu.Unlock()
		if cancelCh != nil {
			close(cancelCh)
			cancelCh = nil
		}
	}()

	setStatus(func(s *Status) {
		s.Running = true
		s.Phase = "preparing"
		s.Image = image
		s.Target = target
		s.Done = 0
		s.Speed = 0
		s.ETA = 0
		s.Err = ""
		s.Hash = ""
		s.Message = "准备中"
		s.Started = time.Now().Unix()
		s.Finished = 0
	})

	src, total, kind, err := openImage(image)
	if err != nil {
		fail(err.Error())
		return
	}
	defer src.Close()

	// 目标校验
	if !isBlockDevice(target) {
		fail("目标不是块设备：" + target)
		return
	}
	name := filepath.Base(target)
	sz := devSizeBytes(name)
	if sz == 0 {
		fail("读不到目标容量：" + target)
		return
	}
	if total > 0 && total > sz {
		fail(fmt.Sprintf("镜像 %s 大于目标容量 %s", humanBytes(total), humanBytes(sz)))
		return
	}
	if "/dev/"+name == bootDisk() {
		fail("拒绝对启动介质自身写入：" + target)
		return
	}
	if m := mountsOf(target); len(m) > 0 {
		fail("目标上仍有分区被挂载：" + strings.Join(m, ", "))
		return
	}

	setStatus(func(s *Status) {
		s.Total = total
		s.Phase = "writing"
		s.Message = fmt.Sprintf("写入 %s（%s 镜像）", target, kind)
	})

	f, err := os.OpenFile(target, os.O_WRONLY|os.O_SYNC, 0)
	if err != nil {
		fail("打不开目标设备：" + err.Error())
		return
	}
	defer f.Close()

	var done uint64
	h := sha256.New()
	cw := &countWriter{w: f, n: &done, h: h, total: total, cxl: cancelCh}
	buf := make([]byte, 4<<20)

	started = time.Now()
	lastByte, lastTime = 0, started
	ticker := time.NewTicker(500 * time.Millisecond)
	go func() {
		for range ticker.C {
			mu.Lock()
			if !status.Running {
				mu.Unlock()
				return
			}
			d := atomic.LoadUint64(&done)
			el := time.Since(started).Seconds()
			if el > 0 {
				status.Speed = float64(d) / el
				if status.Total > 0 && status.Speed > 0 {
					status.ETA = int(float64(status.Total-d) / status.Speed)
				}
			}
			status.Done = d
			mu.Unlock()
		}
	}()
	defer ticker.Stop()

	_, cErr := io.CopyBuffer(cw, src, buf)
	setStatus(func(s *Status) { s.Done = atomic.LoadUint64(&done) })

	if cErr != nil {
		if cw.err != nil {
			setStatus(func(s *Status) { s.Phase = "cancelled"; s.Message = "已取消（磁盘内容不完整）" })
			return
		}
		fail("写入失败：" + cErr.Error())
		return
	}
	if err := f.Sync(); err != nil {
		fail("刷盘失败：" + err.Error())
		return
	}

	sum := hex.EncodeToString(h.Sum(nil))
	setStatus(func(s *Status) { s.Hash = sum })

	if !verify {
		setStatus(func(s *Status) {
			s.Phase = "done"
			s.Message = "写入完成（已跳过校验）"
			s.Finished = time.Now().Unix()
		})
		return
	}

	setStatus(func(s *Status) {
		s.Phase = "verifying"
		s.Message = "回读校验中"
		s.Done = 0
	})
	rb, err := os.Open(target)
	if err != nil {
		fail("回读打开失败：" + err.Error())
		return
	}
	defer rb.Close()
	h2 := sha256.New()
	n, err := io.CopyN(h2, rb, int64(atomic.LoadUint64(&done)))
	if err != nil && err != io.EOF {
		fail("回读失败：" + err.Error())
		return
	}
	sum2 := hex.EncodeToString(h2.Sum(nil))
	setStatus(func(s *Status) { s.Done = uint64(n) })
	if sum2 != sum {
		fail(fmt.Sprintf("校验不一致！写入 %s / 回读 %s", sum[:16], sum2[:16]))
		return
	}
	setStatus(func(s *Status) {
		s.Phase = "done"
		s.Message = "写入并校验完成，可以重启进入系统"
		s.Finished = time.Now().Unix()
	})
}

func fail(msg string) {
	setStatus(func(s *Status) {
		s.Phase = "error"
		s.Err = msg
		s.Message = msg
		s.Finished = time.Now().Unix()
	})
}

// ------------------------------------------------------------------ HTTP --

func jsonOut(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(v)
}

// 必须是块设备（排除 /dev/null、字符设备、普通文件）
func isBlockDevice(p string) bool {
	st, err := os.Stat(p)
	if err != nil {
		return false
	}
	return st.Mode()&os.ModeDevice != 0 && st.Mode()&os.ModeCharDevice == 0
}

// 镜像只允许来自受控目录，避免被拿来读任意文件写盘
func isAllowedImage(p string) bool {
	abs, err := filepath.Abs(p)
	if err != nil {
		return false
	}
	ok := false
	for _, d := range []string{imageDir, "/data", "/mnt"} {
		if strings.HasPrefix(abs, d+"/") {
			ok = true
			break
		}
	}
	if !ok {
		return false
	}
	st, err := os.Stat(abs)
	return err == nil && st.Mode().IsRegular() && st.Size() > 0
}

func apiDisks(w http.ResponseWriter, r *http.Request) {
	jsonOut(w, map[string]any{"boot_disk": bootDisk(), "disks": listDisks()})
}

func apiImages(w http.ResponseWriter, r *http.Request) {
	jsonOut(w, map[string]any{"dir": imageDir, "images": listImages()})
}

func apiStatus(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	st := status
	mu.Unlock()
	jsonOut(w, st)
}

func apiProgress(w http.ResponseWriter, r *http.Request) {
	fl, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", 500)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	tk := time.NewTicker(400 * time.Millisecond)
	defer tk.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-tk.C:
			mu.Lock()
			b, _ := json.Marshal(status)
			mu.Unlock()
			fmt.Fprintf(w, "data: %s\n\n", b)
			fl.Flush()
		}
	}
}

func apiFlash(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", 405)
		return
	}
	var req struct {
		Image   string `json:"image"`
		Target  string `json:"target"`
		Verify  bool   `json:"verify"`
		Confirm string `json:"confirm"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	mu.Lock()
	busy := status.Running
	mu.Unlock()
	if busy {
		http.Error(w, "已有任务在运行", 409)
		return
	}
	if !isBlockDevice(req.Target) {
		http.Error(w, "目标不是块设备", 400)
		return
	}
	if !isAllowedImage(req.Image) {
		http.Error(w, "镜像路径不在允许的目录内", 400)
		return
	}
	if req.Confirm != filepath.Base(req.Target) {
		http.Error(w, "确认词不匹配", 400)
		return
	}
	if "/dev/"+filepath.Base(req.Target) == bootDisk() {
		http.Error(w, "拒绝写入启动介质", 400)
		return
	}
	cancelCh = make(chan struct{})
	go runFlash(req.Image, req.Target, req.Verify)
	jsonOut(w, map[string]any{"ok": true})
}

func apiCancel(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	ch := cancelCh
	running := status.Running
	mu.Unlock()
	if running && ch != nil {
		select {
		case <-ch: // 已关闭
		default:
			close(ch)
		}
	}
	jsonOut(w, map[string]any{"ok": true})
}

func apiUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", 405)
		return
	}
	name := r.URL.Query().Get("name")
	if name == "" {
		http.Error(w, "缺少 name", 400)
		return
	}
	name = filepath.Base(name)
	if strings.Contains(name, "..") || strings.HasPrefix(name, ".") {
		http.Error(w, "非法文件名", 400)
		return
	}
	if err := os.MkdirAll(imageDir, 0o755); err != nil {
		http.Error(w, "无法创建镜像目录: "+err.Error(), 500)
		return
	}
	if r.ContentLength > maxUploadB {
		http.Error(w, "文件超过上限", 413)
		return
	}
	tmp := filepath.Join(imageDir, name+".part")
	dst := filepath.Join(imageDir, name)
	f, err := os.Create(tmp)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	n, err := io.Copy(f, io.LimitReader(r.Body, maxUploadB))
	if err != nil {
		f.Close()
		os.Remove(tmp)
		http.Error(w, "写入失败: "+err.Error(), 500)
		return
	}
	f.Sync()
	f.Close()
	if err := os.Rename(tmp, dst); err != nil {
		os.Remove(tmp)
		http.Error(w, err.Error(), 500)
		return
	}
	jsonOut(w, map[string]any{"ok": true, "path": dst, "size": n})
}

func apiDeleteImage(w http.ResponseWriter, r *http.Request) {
	name := filepath.Base(r.URL.Query().Get("name"))
	if name == "" || name == "." || name == "/" {
		http.Error(w, "缺少 name", 400)
		return
	}
	p := filepath.Join(imageDir, name)
	if err := os.Remove(p); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	jsonOut(w, map[string]any{"ok": true})
}

func apiPower(w http.ResponseWriter, r *http.Request) {
	action := r.URL.Query().Get("action")
	go func() {
		time.Sleep(600 * time.Millisecond)
		switch action {
		case "reboot":
			if err := exec.Command("/bin/busybox", "reboot", "-f").Run(); err != nil {
				exec.Command("reboot", "-f").Run()
			}
		case "poweroff":
			if err := exec.Command("/bin/busybox", "poweroff", "-f").Run(); err != nil {
				exec.Command("poweroff", "-f").Run()
			}
		}
	}()
	jsonOut(w, map[string]any{"ok": true})
}

func main() {
	addr := ":80"
	if v := os.Getenv("FX_LISTEN"); v != "" {
		addr = v
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/api/disks", apiDisks)
	mux.HandleFunc("/api/images", apiImages)
	mux.HandleFunc("/api/status", apiStatus)
	mux.HandleFunc("/api/progress", apiProgress)
	mux.HandleFunc("/api/flash", apiFlash)
	mux.HandleFunc("/api/cancel", apiCancel)
	mux.HandleFunc("/api/upload", apiUpload)
	mux.HandleFunc("/api/delete", apiDeleteImage)
	mux.HandleFunc("/api/power", apiPower)
	mux.HandleFunc("/api/sysinfo", func(w http.ResponseWriter, r *http.Request) { jsonOut(w, sysInfo()) })
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		b, err := wwwFS.ReadFile("www/index.html")
		if err != nil {
			http.Error(w, "UI 缺失", 500)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(b)
	})

	log.Printf("fxrecovery %s 启动，监听 %s", version, addr)
	si := sysInfo()
	for _, u := range si["urls"].([]string) {
		log.Printf("控制台: %s", u)
	}
	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}
