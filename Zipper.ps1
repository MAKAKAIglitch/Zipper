<#
    Zipper v1.2 — графическая оболочка для Windows Compact OS (compact.exe /exe)
    Запускай через Zipper.bat (он сам просит права администратора).
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Version = '1.2'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

trap {
    try { [System.Windows.Forms.MessageBox]::Show($_.Exception.ToString(), 'Zipper — ошибка', 'OK', 'Error') | Out-Null } catch {}
    exit 1
}

# ---------------------------------------------------------------- движок (C#)
$cs = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class ZFile
{
    public string Path;
    public long Size;
    public long Disk;
}

public class ZBatch
{
    public List<ZFile> Files = new List<ZFile>();
    public long Bytes;
    public long DiskBefore;
}

public static class ZNative
{
    public static readonly bool IsWindows = Environment.OSVersion.Platform == PlatformID.Win32NT;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetCompressedFileSizeW(string lpFileName, out uint lpFileSizeHigh);

    [DllImport("kernel32.dll")]
    private static extern uint GetOEMCP();

    [DllImport("ntdll.dll")]
    private static extern int NtSetInformationProcess(IntPtr hProcess, int infoClass, ref int info, int length);

    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();

    public static void DpiAware()
    {
        if (!IsWindows) return;
        try { SetProcessDPIAware(); } catch (Exception) { }
    }

    public static Encoding OemEncoding()
    {
        try { if (IsWindows) return Encoding.GetEncoding((int)GetOEMCP()); } catch (Exception) { }
        return Encoding.UTF8;
    }

    private static string LongPath(string p)
    {
        if (p.Length < 240 || p.StartsWith("\\\\?\\")) return p;
        if (p.StartsWith("\\\\")) return "\\\\?\\UNC\\" + p.Substring(2);
        return "\\\\?\\" + p;
    }

    // Physical size of the file on disk (smaller than Size for compressed files).
    public static long DiskSize(string path, long fallback)
    {
        if (!IsWindows) return fallback;
        try
        {
            uint high;
            uint low = GetCompressedFileSizeW(LongPath(path), out high);
            if (low == 0xFFFFFFFF && Marshal.GetLastWin32Error() != 0) return fallback;
            return ((long)high << 32) | low;
        }
        catch (Exception) { return fallback; }
    }

    // 0 = very low, 1 = low, 2 = normal
    public static void SetIoPriority(Process p, int level)
    {
        if (!IsWindows) return;
        try
        {
            int v = level;
            NtSetInformationProcess(p.Handle, 33, ref v, 4);
        }
        catch (Exception) { }
    }
}

public class ZipperEngine
{
    // ---------- settings that can be changed while running ----------
    private volatile int _threads = 2;
    private volatile int _cpuPrio = 1;
    private volatile int _ioPrio = 1;
    private volatile int _load = 100;
    private volatile bool _paused;

    public int Threads { get { return _threads; } set { _threads = value < 1 ? 1 : value; } }
    public int CpuPriority { get { return _cpuPrio; } set { _cpuPrio = value < 0 ? 0 : (value > 2 ? 2 : value); } }
    public int IoPriority { get { return _ioPrio; } set { _ioPrio = value < 0 ? 0 : (value > 2 ? 2 : value); } }
    public int LoadPercent { get { return _load; } set { _load = value < 1 ? 1 : (value > 100 ? 100 : value); } }
    public bool Paused { get { return _paused; } set { _paused = value; } }

    // ---------- options for the next run ----------
    public string Algorithm = "lzx";
    public bool Decompress;
    public bool Force;
    public bool SkipMedia = true;
    public string CompactPath;
    public long MinSize = 4096;
    public int MaxWorkers = 0;   // 0 = number of logical processors

    // ---------- state ----------
    private volatile bool _cancel;
    private volatile bool _fatal;
    private volatile int _state;      // 0 idle, 1 scanning, 2 running, 3 done, 4 stopped, 5 analyzed, 6 error
    private volatile string _lastError = "";
    private int _stopCount;
    private int _alive;
    private int _exitWarned;
    private int _logCount;
    private string _root;
    private bool _analyzeOnly;
    private Stopwatch _sw = new Stopwatch();
    private ConcurrentQueue<ZBatch> _queue = new ConcurrentQueue<ZBatch>();
    private ConcurrentQueue<string> _log = new ConcurrentQueue<string>();
    private readonly List<Process> _procs = new List<Process>();
    private readonly object _plock = new object();

    private long _scanned, _allFiles, _allBytes, _allDisk;
    private long _selFiles, _selBytes, _selDisk;
    private long _doneFiles, _doneBytes, _ok, _err, _diskDelta;

    public int State { get { return _state; } }
    public bool Busy { get { return _state == 1 || _state == 2; } }
    public string LastError { get { return _lastError; } }
    public int StopCount { get { return _stopCount; } }
    public long ElapsedMs { get { return _sw.ElapsedMilliseconds; } }

    public long Scanned { get { return Interlocked.Read(ref _scanned); } }
    public long AllFiles { get { return Interlocked.Read(ref _allFiles); } }
    public long AllBytes { get { return Interlocked.Read(ref _allBytes); } }
    public long AllDisk { get { return Interlocked.Read(ref _allDisk); } }
    public long SelFiles { get { return Interlocked.Read(ref _selFiles); } }
    public long SelBytes { get { return Interlocked.Read(ref _selBytes); } }
    public long SelDisk { get { return Interlocked.Read(ref _selDisk); } }
    public long DoneFiles { get { return Interlocked.Read(ref _doneFiles); } }
    public long DoneBytes { get { return Interlocked.Read(ref _doneBytes); } }
    public long OkCount { get { return Interlocked.Read(ref _ok); } }
    public long ErrCount { get { return Interlocked.Read(ref _err); } }
    // bytes freed on disk (negative after decompression)
    public long DiskDelta { get { return Interlocked.Read(ref _diskDelta); } }

    private static readonly HashSet<string> MediaExt = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        ".zip", ".rar", ".7z", ".gz", ".bz2", ".xz", ".zst", ".cab", ".lz4",
        ".mp3", ".mp4", ".m4a", ".m4v", ".mkv", ".avi", ".mov", ".webm", ".ogg", ".ogv", ".opus", ".flac", ".wma", ".wmv",
        ".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".bik", ".bk2", ".usm"
    };

    private static readonly string[] ErrWords = new string[]
    {
        "denied", "failed", "error", "used by another", "cannot",
        "\u043e\u0442\u043a\u0430\u0437\u0430\u043d\u043e", "\u043d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c", "\u043e\u0448\u0438\u0431\u043a",
        "\u0434\u0440\u0443\u0433\u0438\u043c \u043f\u0440\u043e\u0446\u0435\u0441\u0441\u043e\u043c", "\u043d\u0435 \u043c\u043e\u0436\u0435\u0442",
        "\u043d\u0435 \u0443\u0434\u0430\u0435\u0442\u0441\u044f", "\u043d\u0435 \u0443\u0434\u0430\u0451\u0442\u0441\u044f", "\u043d\u0435 \u043f\u043e\u0434\u0434\u0435\u0440\u0436"
    };

    public ZipperEngine()
    {
        CompactPath = Path.Combine(Environment.SystemDirectory, "compact.exe");
    }

    // ---------- public control ----------
    public bool Begin(string root, bool analyzeOnly)
    {
        if (Busy) return false;
        _scanned = 0; _allFiles = 0; _allBytes = 0; _allDisk = 0;
        _selFiles = 0; _selBytes = 0; _selDisk = 0;
        _doneFiles = 0; _doneBytes = 0; _ok = 0; _err = 0; _diskDelta = 0;
        _queue = new ConcurrentQueue<ZBatch>();
        _fatal = false; _cancel = false; _paused = false;
        _stopCount = 0; _exitWarned = 0; _lastError = "";
        _root = root; _analyzeOnly = analyzeOnly;
        _sw = Stopwatch.StartNew();
        _state = 1;
        Thread t = new Thread(new ThreadStart(Run));
        t.IsBackground = true;
        t.Name = "zipper-main";
        t.Start();
        return true;
    }

    // first call: stop gracefully (finish current files); second call: kill running compact.exe
    public void Stop()
    {
        if (!Busy) return;
        int n = Interlocked.Increment(ref _stopCount);
        _cancel = true;
        if (n >= 2) KillAll();
    }

    public string[] DrainLog(int max)
    {
        List<string> l = new List<string>();
        string s;
        while (l.Count < max && _log.TryDequeue(out s))
        {
            l.Add(s);
            Interlocked.Decrement(ref _logCount);
        }
        return l.ToArray();
    }

    // ---------- internals ----------
    private void Enqueue(string s)
    {
        if (Interlocked.Increment(ref _logCount) > 3000)
        {
            Interlocked.Decrement(ref _logCount);
            return;
        }
        _log.Enqueue(s);
    }

    private static string Short(string s)
    {
        if (s == null) return "";
        return s.Length > 300 ? s.Substring(0, 300) + "..." : s;
    }

    private void Finish(int state)
    {
        _sw.Stop();
        _state = state;
    }

    private void KillAll()
    {
        List<Process> copy;
        lock (_plock) { copy = new List<Process>(_procs); }
        foreach (Process p in copy)
        {
            try { if (!p.HasExited) p.Kill(); } catch (Exception) { }
        }
    }

    private void Run()
    {
        try
        {
            List<ZFile> sel = new List<ZFile>();
            Scan(_root, sel);
            if (_cancel) { Finish(4); return; }
            if (_analyzeOnly) { Finish(5); return; }
            if (sel.Count == 0) { Finish(3); return; }
            BuildQueue(sel);
            StartWorkers();
        }
        catch (Exception ex)
        {
            _lastError = Short(ex.Message);
            Finish(6);
        }
    }

    private static bool IsSkipDir(string name)
    {
        return string.Equals(name, "System Volume Information", StringComparison.OrdinalIgnoreCase)
            || string.Equals(name, "$RECYCLE.BIN", StringComparison.OrdinalIgnoreCase);
    }

    private void Scan(string root, List<ZFile> sel)
    {
        Stack<string> stack = new Stack<string>();
        stack.Push(root);
        while (stack.Count > 0 && !_cancel)
        {
            string dir = stack.Pop();
            DirectoryInfo di;
            try { di = new DirectoryInfo(dir); }
            catch (Exception ex) { Enqueue("W|" + dir + ": " + ex.Message); continue; }

            List<string> subs = new List<string>();
            try
            {
                foreach (DirectoryInfo sd in di.EnumerateDirectories())
                {
                    if ((sd.Attributes & FileAttributes.ReparsePoint) != 0) continue; // junctions / symlinks
                    if (IsSkipDir(sd.Name)) continue;
                    subs.Add(sd.FullName);
                }
            }
            catch (Exception ex) { Enqueue("W|" + dir + ": " + ex.Message); }

            try
            {
                foreach (FileInfo fi in di.EnumerateFiles())
                {
                    if (_cancel) break;
                    Consider(fi, sel);
                }
            }
            catch (Exception ex) { Enqueue("W|" + dir + ": " + ex.Message); }

            subs.Sort(StringComparer.OrdinalIgnoreCase);
            for (int i = subs.Count - 1; i >= 0; i--) stack.Push(subs[i]);
        }
    }

    private void Consider(FileInfo fi, List<ZFile> sel)
    {
        long size;
        int attr;
        string full;
        try { size = fi.Length; attr = (int)fi.Attributes; full = fi.FullName; }
        catch (Exception) { return; }

        long disk = ZNative.DiskSize(full, size);
        Interlocked.Increment(ref _scanned);
        Interlocked.Increment(ref _allFiles);
        Interlocked.Add(ref _allBytes, size);
        Interlocked.Add(ref _allDisk, disk);

        // cloud placeholders / offline files: touching them would download them
        if ((attr & (0x1000 | 0x40000 | 0x400000)) != 0) return;
        // EFS-encrypted files cannot be compressed
        if ((attr & 0x4000) != 0) return;

        if (Decompress)
        {
            // 0x400 reparse point (Compact OS files are WOF reparse points), 0x800 NTFS-compressed
            bool packed = (attr & 0x400) != 0 || (attr & 0x800) != 0 || disk < size;
            if (!packed) return;
        }
        else
        {
            if (size < MinSize) return;
            if ((attr & 0x200) != 0) return;                      // sparse
            if (!Force && (attr & 0x400) != 0) return;            // already compressed (or a link)
            if (SkipMedia && MediaExt.Contains(fi.Extension)) return;
        }

        ZFile z = new ZFile();
        z.Path = full; z.Size = size; z.Disk = disk;
        sel.Add(z);
        Interlocked.Increment(ref _selFiles);
        Interlocked.Add(ref _selBytes, size);
        Interlocked.Add(ref _selDisk, disk);
    }

    private void BuildQueue(List<ZFile> files)
    {
        const long MaxBytes = 128L * 1024 * 1024;
        const int MaxFiles = 150;
        const int MaxChars = 20000;

        ZBatch cur = new ZBatch();
        int chars = 0;
        foreach (ZFile f in files)
        {
            int add = f.Path.Length + 3;
            bool full = cur.Files.Count > 0 &&
                (cur.Files.Count >= MaxFiles || cur.Bytes + f.Size > MaxBytes || chars + add > MaxChars);
            if (full)
            {
                _queue.Enqueue(cur);
                cur = new ZBatch();
                chars = 0;
            }
            cur.Files.Add(f);
            cur.Bytes += f.Size;
            cur.DiskBefore += f.Disk;
            chars += add;
        }
        if (cur.Files.Count > 0) _queue.Enqueue(cur);
    }

    private void StartWorkers()
    {
        int n = MaxWorkers > 0 ? MaxWorkers : Environment.ProcessorCount;
        if (n < 1) n = 1;
        if (n > 32) n = 32;
        _alive = n;
        _state = 2;
        for (int i = 0; i < n; i++)
        {
            int idx = i;
            Thread t = new Thread(delegate() { Worker(idx); });
            t.IsBackground = true;
            t.Name = "zipper-worker-" + i;
            t.Start();
        }
    }

    private void Worker(int index)
    {
        try
        {
            while (!_cancel)
            {
                if (_queue.IsEmpty) break;
                if (index >= _threads || _paused) { Thread.Sleep(150); continue; }
                ZBatch b;
                if (!_queue.TryDequeue(out b)) break;
                Stopwatch sw = Stopwatch.StartNew();
                RunBatch(b);
                sw.Stop();
                Throttle(sw.ElapsedMilliseconds);
            }
        }
        catch (Exception ex)
        {
            _lastError = Short(ex.Message);
            _fatal = true;
            _cancel = true;
        }
        finally
        {
            if (Interlocked.Decrement(ref _alive) == 0)
            {
                if (_fatal) Finish(6);
                else if (_cancel) Finish(4);
                else Finish(3);
            }
        }
    }

    // duty cycle: after working for T ms, sleep T * (100 - load) / load ms
    private void Throttle(long workedMs)
    {
        int load = _load;
        if (load >= 100) return;
        long sleep = workedMs * (100 - load) / load;
        if (sleep > 60000) sleep = 60000;
        long waited = 0;
        while (waited < sleep && !_cancel && _load < 100)
        {
            Thread.Sleep(100);
            waited += 100;
        }
    }

    private static ProcessPriorityClass ToPriority(int level)
    {
        if (level <= 0) return ProcessPriorityClass.Idle;
        if (level == 1) return ProcessPriorityClass.BelowNormal;
        return ProcessPriorityClass.Normal;
    }

    private void RunBatch(ZBatch b)
    {
        StringBuilder sb = new StringBuilder();
        if (Decompress)
        {
            sb.Append("/u /a /i /exe");
        }
        else
        {
            sb.Append("/c /a /i");
            if (Force) sb.Append(" /f");
            sb.Append(" /exe:").Append(Algorithm);
        }
        foreach (ZFile f in b.Files) sb.Append(" \"").Append(f.Path).Append("\"");

        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = CompactPath;
        psi.Arguments = sb.ToString();
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        Encoding enc = ZNative.OemEncoding();
        psi.StandardOutputEncoding = enc;
        psi.StandardErrorEncoding = enc;

        Process p = new Process();
        p.StartInfo = psi;
        DataReceivedEventHandler h = delegate(object s, DataReceivedEventArgs e)
        {
            if (e.Data != null) HandleLine(e.Data);
        };
        p.OutputDataReceived += h;
        p.ErrorDataReceived += h;

        try
        {
            p.Start();
        }
        catch (Win32Exception ex)
        {
            _lastError = Short(ex.Message);
            _fatal = true;
            _cancel = true;
            p.Dispose();
            return;
        }

        lock (_plock) { _procs.Add(p); }
        try
        {
            try { p.PriorityClass = ToPriority(_cpuPrio); } catch (Exception) { }
            ZNative.SetIoPriority(p, _ioPrio);
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            p.WaitForExit();
            if (p.ExitCode != 0 && !_cancel && Interlocked.CompareExchange(ref _exitWarned, 1, 0) == 0)
                Enqueue("W|compact.exe exit code " + p.ExitCode);
        }
        finally
        {
            lock (_plock) { _procs.Remove(p); }
            p.Dispose();
        }

        long after = 0;
        foreach (ZFile f in b.Files) after += ZNative.DiskSize(f.Path, f.Disk);
        Interlocked.Add(ref _diskDelta, b.DiskBefore - after);
        Interlocked.Add(ref _doneFiles, b.Files.Count);
        Interlocked.Add(ref _doneBytes, b.Bytes);
    }

    private void HandleLine(string line)
    {
        if (line.Length == 0) return;
        if (line.IndexOf("[OK]", StringComparison.Ordinal) >= 0)
        {
            Interlocked.Increment(ref _ok);
            return;
        }
        foreach (string w in ErrWords)
        {
            if (line.IndexOf(w, StringComparison.OrdinalIgnoreCase) >= 0)
            {
                Interlocked.Increment(ref _err);
                Enqueue("E|" + line.Trim());
                return;
            }
        }
    }
}

public class ZForm : System.Windows.Forms.Form
{
    [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern uint DragQueryFileW(System.IntPtr hDrop, uint iFile, System.Text.StringBuilder lpszFile, uint cch);

    [System.Runtime.InteropServices.DllImport("shell32.dll")]
    private static extern void DragAcceptFiles(System.IntPtr hWnd, bool fAccept);

    [System.Runtime.InteropServices.DllImport("shell32.dll")]
    private static extern void DragFinish(System.IntPtr hDrop);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool ChangeWindowMessageFilterEx(System.IntPtr hWnd, uint msg, uint action, System.IntPtr changeInfo);

    public event System.EventHandler Dropped;
    public string DroppedPath = "";

    protected override void OnHandleCreated(System.EventArgs e)
    {
        base.OnHandleCreated(e);
        try
        {
            // let drops from a non-elevated Explorer reach this elevated window
            ChangeWindowMessageFilterEx(this.Handle, 0x233, 1, System.IntPtr.Zero);
            ChangeWindowMessageFilterEx(this.Handle, 0x49, 1, System.IntPtr.Zero);
            ChangeWindowMessageFilterEx(this.Handle, 0x4A, 1, System.IntPtr.Zero);
            DragAcceptFiles(this.Handle, true);
        }
        catch (System.Exception) { }
    }

    protected override void WndProc(ref System.Windows.Forms.Message m)
    {
        if (m.Msg == 0x233)
        {
            try
            {
                uint len = DragQueryFileW(m.WParam, 0, null, 0);
                System.Text.StringBuilder sb = new System.Text.StringBuilder((int)len + 2);
                DragQueryFileW(m.WParam, 0, sb, len + 1);
                DragFinish(m.WParam);
                DroppedPath = sb.ToString();
                if (Dropped != null) Dropped(this, System.EventArgs.Empty);
            }
            catch (System.Exception) { }
            return;
        }
        base.WndProc(ref m);
    }
}
'@

try {
    Add-Type -TypeDefinition $cs -Language CSharp -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing', 'System.Core'
} catch {
    [System.Windows.Forms.MessageBox]::Show("Не удалось скомпилировать движок:`r`n" + $_.Exception.Message, 'Zipper', 'OK', 'Error') | Out-Null
    exit 1
}

try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch {}
[ZNative]::DpiAware()

# ---------------------------------------------------------------- настройки и лог
$script:dataDir = Join-Path $env:LOCALAPPDATA 'Zipper'
$script:settingsFile = Join-Path $script:dataDir 'settings.json'
$script:logFile = Join-Path $script:dataDir 'zipper.log'
try { [System.IO.Directory]::CreateDirectory($script:dataDir) | Out-Null } catch {}

# ---------------------------------------------------------------- localization
$script:translations = @{
    'Zipper — Compact OS' = 'Zipper — Compact OS'
    'Язык' = 'Language'
    'Сжатие игр и программ без потери данных (Compact OS: LZX / XPRESS). Файлы остаются рабочими, распаковывать не нужно.' = 'Compress games and apps without data loss (Compact OS: LZX / XPRESS). Files stay usable without unpacking.'
    'ПАПКА' = 'TARGET FOLDER'
    'Обзор…' = 'Browse…'
    'Выбери папку с игрой или программой (можно перетащить её в окно).' = 'Choose a game or app folder (you can also drag it into this window).'
    'РЕЖИМ' = 'MODE'
    'Без потери данных, файлы работают как обычно.' = 'Lossless compression; files work as usual.'
    'Пересжимать уже сжатые файлы (/f)' = 'Recompress already-compressed files (/f)'
    'Пропускать архивы и медиа (zip, mp4, jpg …) — они почти не сжимаются' = 'Skip archives and media (zip, mp4, jpg …) — they rarely compress further'
    'НАГРУЗКА  (можно менять прямо во время работы)' = 'CPU & DISK LOAD  (adjustable while running)'
    'Тихо' = 'Quiet'
    'Баланс' = 'Balanced'
    'Максимум' = 'Maximum'
    'Потоки (параллельно)' = 'Worker threads'
    'Приоритет процессора' = 'CPU priority'
    'Приоритет диска' = 'Disk I/O priority'
    '{0} из {1}' = '{0} of {1}'
    'Диск {0:N0}%' = 'Disk {0:N0}%'
    'Лимит нагрузки' = 'Workload limit'
    'Лимит — пауза после каждой порции: при 50% поток отдыхает столько же, сколько работал. Работает вместе с приоритетами.' = 'The limit adds a pause after each batch. At 50%, workers rest about as long as they work. Combined with priority settings.'
    'Загрузка системы:' = 'System usage:'
    'CPU 0%' = 'CPU 0%'
    'Диск 0%' = 'Disk 0%'
    'ПРОГРЕСС' = 'PROGRESS'
    'Готов к работе.' = 'Ready.'
    'Сжать' = 'Compress'
    'Расжать' = 'Decompress'
    'Снять сжатие' = 'Decompress'
    'Анализ' = 'Analyze'
    'Пауза' = 'Pause'
    'Продолжить' = 'Resume'
    'Стоп' = 'Stop'
    'Прервать' = 'Abort'
    'Лог' = 'Log'
    'Выбери папку для сжатия' = 'Choose a folder to compress'
    'Сетевой путь: Compact OS на сетевых папках не работает.' = 'Network path: Compact OS does not work on network folders.'
    'Сетевые пути не поддерживаются: Compact OS работает только на локальном NTFS.' = 'Network paths are not supported: Compact OS requires a local NTFS drive.'
    'Сетевые диски не поддерживаются.' = 'Network drives are not supported.'
    'Не удалось определить диск.' = 'Could not identify the drive.'
    'Диск {0} отформатирован в {1}. Compact OS работает только на NTFS.' = 'Drive {0} is formatted as {1}. Compact OS requires NTFS.'
    'Папку Windows сжимать нельзя — система может перестать загружаться.' = 'Do not compress the Windows folder — the system may fail to boot.'
    'Корень системного диска сжимать нельзя (там Windows). Выбери конкретную папку с игрой или программой.' = 'Do not compress the system-drive root. Choose a specific game or application folder.'
    'Выбран корень диска {0} — будет сжато вообще всё на нём. Продолжить?' = 'Drive root {0} is selected — everything on it will be compressed. Continue?'
    'Это системная папка ({0}): там много файлов, которые постоянно используются. Лучше выбрать конкретную подпапку. Всё равно продолжить?' = 'This is a system folder ({0}) with many files in use. A specific subfolder is safer. Continue anyway?'
    'Сначала выбери папку.' = 'Choose a folder first.'
    'Такой папки нет.' = 'That folder does not exist.'
    'Диск {0}: · {1}' = 'Drive {0}: · {1}'
    ' · свободно ' = ' · free '
    ' — Compact OS работает только на NTFS!' = ' — Compact OS requires NTFS!'
    ' — на HDD лучше 1–2 потока' = ' — 1–2 threads are recommended for HDDs'
    '100% — без пауз' = '100% — no pauses'
    '{0}% — с паузами' = '{0}% — throttled'
    'Расжатие' = 'Decompression'
    'Сжатие ' = 'Compression '
    'Анализ завершён.' = 'Analysis complete.'
    'Готово.' = 'Done.'
    'Нечего делать.' = 'Nothing to do.'
    'Остановлено.' = 'Stopped.'
    'Ошибка.' = 'Error.'
    'Файлов: {0:N0}, объём {1}, на диске {2} (уже сэкономлено {3:N0}%)' = 'Files: {0:N0}, logical size {1}, on disk {2} (already saved {3:N0}%)'
    'В папке файлов: {0:N0} ({1}). К обработке: {2:N0} ({3}).' = 'Files found: {0:N0} ({1}). Eligible to process: {2:N0} ({3}).'
    'Можно сжать: {0:N0} файлов, {1}' = 'Eligible to compress: {0:N0} files, {1}'
    'Нечего делать: подходящих файлов нет (всё уже обработано или файлы слишком мелкие / исключены).' = 'Nothing to do: no eligible files (already processed, too small, or excluded).'
    'Готово за {0}. Занято дополнительно: {1}. OK: {2:N0}, ошибок: {3:N0}' = 'Finished in {0}. Extra disk space used: {1}. OK: {2:N0}, errors: {3:N0}'
    'Готово за {0}. Освобождено: {1} ({2:N1}%). OK: {3:N0}, ошибок: {4:N0}' = 'Finished in {0}. Space freed: {1} ({2:N1}%). OK: {3:N0}, errors: {4:N0}'
    'Остановлено. Обработано файлов: {0:N0} из {1:N0}.' = 'Stopped. Processed {0:N0} of {1:N0} files.'
    'Ошибка: ' = 'Error: '
    'Сканирование… файлов: {0:N0}' = 'Scanning… files: {0:N0}'
    '   [ПАУЗА]' = '   [PAUSED]'
    'Файлов: {0:N0} / {1:N0}    Данные: {2} / {3}    Скорость: {4}/с    Осталось: {5}{6}' = 'Files: {0:N0} / {1:N0}    Data: {2} / {3}    Speed: {4}/s    Remaining: {5}{6}'
    'OK: {0:N0}    Ошибок: {1:N0}    Освобождено на диске: {2}' = 'OK: {0:N0}    Errors: {1:N0}    Space freed: {2}'
    'Идёт работа. Прервать и выйти?' = 'A task is running. Stop it and exit?'
    'Не удалось скомпилировать движок:' = 'Could not compile the engine:'
    'Прервано принудительно.' = 'Force-stopped.'
    'Останавливаю: дожидаюсь завершения текущих файлов… Повторное нажатие прервёт сразу.' = 'Stopping after the current batch… Press Stop again to abort immediately.'
}
function T([string]$key) {
    if ($script:language -eq 'en' -and $script:translations.ContainsKey($key)) { return [string]$script:translations[$key] }
    return $key
}

function Read-Settings {
    try {
        if (Test-Path -LiteralPath $script:settingsFile) {
            return (Get-Content -LiteralPath $script:settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
    } catch {}
    return $null
}

function Write-LogFile([string]$text) {
    try {
        $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}{2}' -f (Get-Date), $text, "`r`n"
        [System.IO.File]::AppendAllText($script:logFile, $line, [System.Text.Encoding]::UTF8)
    } catch {}
}

# ---------------------------------------------------------------- форматирование
function Fmt-Bytes([double]$b) {
    $neg = $b -lt 0
    $b = [Math]::Abs($b)
    if ($script:language -eq 'en') { $units = 'B', 'KB', 'MB', 'GB', 'TB' } else { $units = 'Б', 'КБ', 'МБ', 'ГБ', 'ТБ' }
    $i = 0
    while ($b -ge 1024 -and $i -lt 4) { $b = $b / 1024; $i++ }
    if ($i -eq 0) { $s = '{0:N0} {1}' -f $b, $units[$i] } else { $s = '{0:N2} {1}' -f $b, $units[$i] }
    if ($neg) { return "-$s" }
    return $s
}

function Fmt-Time([double]$sec) {
    if ([double]::IsNaN($sec) -or [double]::IsInfinity($sec) -or $sec -lt 0) { return '—' }
    $ts = [TimeSpan]::FromSeconds([Math]::Min($sec, 359999))
    if ($ts.TotalHours -ge 1) { return '{0}:{1:00}:{2:00}' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds }
    return '{0:00}:{1:00}' -f $ts.Minutes, $ts.Seconds
}

# ---------------------------------------------------------------- палитра и шрифты
function Col([string]$hex) { return [System.Drawing.ColorTranslator]::FromHtml($hex) }
$cBg = Col '#13151A'; $cCard = Col '#1C1F26'; $cInput = Col '#262A33'; $cTrack = Col '#2C313B'
$cText = Col '#E7E9ED'; $cMuted = Col '#8E96A3'; $cBtn = Col '#2F3541'
$cAccent = Col '#4C8DFF'; $cGreen = Col '#3FB950'; $cRed = Col '#F0615A'; $cYellow = Col '#E3B341'; $cDanger = Col '#C9433D'
$fBase = New-Object System.Drawing.Font('Segoe UI', 9)
$fTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 18)
$fCap = New-Object System.Drawing.Font('Segoe UI Semibold', 8)
$fBold = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$fMono = New-Object System.Drawing.Font('Consolas', 9)

# ---------------------------------------------------------------- фабрики контролов
function New-Ctl([string]$type, [int]$x, [int]$y, [int]$w, [int]$h) {
    $c = New-Object $type
    $c.Location = New-Object System.Drawing.Point($x, $y)
    $c.Size = New-Object System.Drawing.Size($w, $h)
    return $c
}

function Add-Label($parent, [string]$text, [int]$x, [int]$y, [int]$w, [int]$h, $fore = $null, $font = $null) {
    $l = New-Ctl 'System.Windows.Forms.Label' $x $y $w $h
    $l.Text = $text
    if ($fore) { $l.ForeColor = $fore } else { $l.ForeColor = $cText }
    $l.BackColor = [System.Drawing.Color]::Transparent
    if ($font) { $l.Font = $font }
    $parent.Controls.Add($l)
    return $l
}

function Add-Card([int]$x, [int]$y, [int]$w, [int]$h, [string]$title) {
    $p = New-Ctl 'System.Windows.Forms.Panel' $x $y $w $h
    $p.BackColor = $cCard
    $form.Controls.Add($p)
    $null = Add-Label $p $title 14 8 300 16 $cMuted $fCap
    return $p
}

function Add-Button($parent, [string]$text, [int]$x, [int]$y, [int]$w, [int]$h, $bg) {
    $b = New-Ctl 'System.Windows.Forms.Button' $x $y $w $h
    $b.Text = $text
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.UseVisualStyleBackColor = $false
    $b.BackColor = $bg
    $b.ForeColor = [System.Drawing.Color]::White
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $parent.Controls.Add($b)
    return $b
}

function Add-Combo($parent, [string[]]$items, [int]$x, [int]$y, [int]$w, [int]$sel) {
    $c = New-Ctl 'System.Windows.Forms.ComboBox' $x $y $w 26
    $c.DropDownStyle = 'DropDownList'
    $c.FlatStyle = 'Flat'
    $c.BackColor = $cInput
    $c.ForeColor = $cText
    $c.Items.AddRange([object[]]$items)
    $c.SelectedIndex = $sel
    $parent.Controls.Add($c)
    return $c
}

function Add-Track($parent, [int]$min, [int]$max, [int]$val, [int]$x, [int]$y, [int]$w) {
    $t = New-Object System.Windows.Forms.TrackBar
    $t.AutoSize = $false
    $t.Location = New-Object System.Drawing.Point($x, $y)
    $t.Size = New-Object System.Drawing.Size($w, 34)
    $t.Minimum = $min
    $t.Maximum = $max
    $t.Value = [Math]::Max($min, [Math]::Min($max, $val))
    $t.TickStyle = 'None'
    $t.BackColor = $cCard
    $parent.Controls.Add($t)
    return $t
}

function Add-Bar($parent, [int]$x, [int]$y, [int]$w, [int]$h, $color) {
    $t = New-Ctl 'System.Windows.Forms.Panel' $x $y $w $h
    $t.BackColor = $cTrack
    $f = New-Ctl 'System.Windows.Forms.Panel' 0 0 0 $h
    $f.BackColor = $color
    $t.Controls.Add($f)
    $parent.Controls.Add($t)
    return @{ Track = $t; Fill = $f }
}

function Set-Bar($bar, [double]$r, $color = $null) {
    if ($r -lt 0) { $r = 0 }
    if ($r -gt 1) { $r = 1 }
    $bar.Fill.Width = [int][Math]::Round($bar.Track.Width * $r)
    if ($color) { $bar.Fill.BackColor = $color }
}

# ---------------------------------------------------------------- движок и окно
$engine = New-Object ZipperEngine
$cores = [Math]::Max(1, [Environment]::ProcessorCount)
$settings = Read-Settings
$script:language = 'ru'
if ($settings -and [string]$settings.language -eq 'en') { $script:language = 'en' }
$script:languageChanging = $false

$form = New-Object ZForm
$form.Text = "Zipper $($script:Version) — Compact OS"
$form.StartPosition = 'CenterScreen'
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF -ArgumentList 96, 96
$form.AutoScaleMode = 'Dpi'
$form.ClientSize = New-Object System.Drawing.Size(860, 740)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.BackColor = $cBg
$form.ForeColor = $cText
$form.Font = $fBase
$form.AutoScroll = $true

$null = Add-Label $form 'Zipper' 18 8 200 36 $cText $fTitle
$null = Add-Label $form 'Сжатие игр и программ без потери данных (Compact OS: LZX / XPRESS). Файлы остаются рабочими, распаковывать не нужно.' 20 46 820 18 $cMuted
$null = Add-Label $form 'Язык' 662 17 52 20 $cMuted $fCap
$cmbLanguage = Add-Combo $form @('Русский', 'English') 716 12 128 28 0

# --- Карточка: папка
$cardPath = Add-Card 16 74 828 84 'ПАПКА'
$txtPath = New-Ctl 'System.Windows.Forms.TextBox' 14 30 688 26
$txtPath.BackColor = $cInput; $txtPath.ForeColor = $cText; $txtPath.BorderStyle = 'FixedSingle'
$txtPath.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$cardPath.Controls.Add($txtPath)
$btnBrowse = Add-Button $cardPath 'Обзор…' 712 28 102 30 $cBtn
$lblInfo = Add-Label $cardPath '' 14 62 800 18 $cMuted

# --- Карточка: режим
$cardMode = Add-Card 16 168 828 92 'РЕЖИМ'
$cmbAlg = Add-Combo $cardMode @('XPRESS 4K — быстро, слабое сжатие', 'XPRESS 8K — стандарт', 'XPRESS 16K — сильнее', 'LZX — максимум (рекомендую для игр)') 14 30 330 3
$null = Add-Label $cardMode 'Без потери данных, файлы работают как обычно.' 14 62 340 18 $cMuted
$chkForce = New-Ctl 'System.Windows.Forms.CheckBox' 372 28 440 22
$chkForce.Text = 'Пересжимать уже сжатые файлы (/f)'; $chkForce.ForeColor = $cText; $chkForce.BackColor = [System.Drawing.Color]::Transparent
$cardMode.Controls.Add($chkForce)
$chkMedia = New-Ctl 'System.Windows.Forms.CheckBox' 372 54 440 22
$chkMedia.Text = 'Пропускать архивы и медиа (zip, mp4, jpg …) — они почти не сжимаются'; $chkMedia.ForeColor = $cText; $chkMedia.BackColor = [System.Drawing.Color]::Transparent
$chkMedia.Checked = $true
$cardMode.Controls.Add($chkMedia)

# --- Карточка: нагрузка
$cardLoad = Add-Card 16 270 828 206 'НАГРУЗКА  (можно менять прямо во время работы)'
$btnQuiet = Add-Button $cardLoad 'Тихо' 574 6 76 24 $cBtn
$btnBal = Add-Button $cardLoad 'Баланс' 654 6 76 24 $cBtn
$btnMax = Add-Button $cardLoad 'Максимум' 734 6 76 24 $cBtn

$null = Add-Label $cardLoad 'Потоки (параллельно)' 14 46 170 20
$tbThreads = Add-Track $cardLoad 1 $cores ([Math]::Max(1, [int][Math]::Floor($cores / 2))) 190 38 420
$lblThreads = Add-Label $cardLoad '' 620 46 200 20 $cText $fBold

$null = Add-Label $cardLoad 'Приоритет процессора' 14 90 170 20
$cmbCpu = Add-Combo $cardLoad @('Самый низкий (Idle)', 'Ниже обычного', 'Обычный') 190 86 240 1
$null = Add-Label $cardLoad 'Приоритет диска' 460 90 120 20
$cmbIo = Add-Combo $cardLoad @('Очень низкий', 'Низкий', 'Обычный') 584 86 230 1

$null = Add-Label $cardLoad 'Лимит нагрузки' 14 130 170 20
$tbLoad = Add-Track $cardLoad 1 20 20 190 122 420
$lblLoad = Add-Label $cardLoad '' 620 130 200 20 $cText $fBold

$lblCpuTxt = Add-Label $cardLoad 'CPU 0%' 190 166 90 18 $cMuted
$barCpu = Add-Bar $cardLoad 280 171 150 8 $cGreen
$lblDskTxt = Add-Label $cardLoad 'Диск 0%' 460 166 90 18 $cMuted
$barDsk = Add-Bar $cardLoad 550 171 150 8 $cGreen
$null = Add-Label $cardLoad 'Загрузка системы:' 14 166 170 18 $cMuted
$lblNote = Add-Label $cardLoad 'Лимит — пауза после каждой порции: при 50% поток отдыхает столько же, сколько работал. Работает вместе с приоритетами.' 14 186 800 16 $cMuted $fCap

# --- Карточка: прогресс
$cardProg = Add-Card 16 486 828 86 'ПРОГРЕСС'
$barMain = Add-Bar $cardProg 14 28 800 10 $cAccent
$lblStat1 = Add-Label $cardProg 'Готов к работе.' 14 44 800 18 $cText
$lblStat2 = Add-Label $cardProg '' 14 63 800 18 $cMuted

# --- Кнопки действий
$btnCompress = Add-Button $form 'Сжать' 16 582 150 38 $cAccent
$btnCompress.Font = $fBold
$btnDecompress = Add-Button $form 'Снять сжатие' 174 582 120 38 $cBtn
$btnAnalyze = Add-Button $form 'Анализ' 302 582 110 38 $cBtn
$btnPause = Add-Button $form 'Пауза' 560 582 100 38 $cBtn
$btnStop = Add-Button $form 'Стоп' 668 582 90 38 $cDanger
$btnLogOpen = Add-Button $form 'Лог' 766 582 78 38 $cBtn
$btnPause.Enabled = $false
$btnStop.Enabled = $false

# --- Лог
$rtb = New-Ctl 'System.Windows.Forms.RichTextBox' 16 630 828 94
$rtb.BackColor = $cCard; $rtb.ForeColor = $cText; $rtb.BorderStyle = 'None'
$rtb.ReadOnly = $true; $rtb.Font = $fMono; $rtb.DetectUrls = $false
$form.Controls.Add($rtb)

# ---------------------------------------------------------------- локализация контролов
function Localize-Controls($parent) {
    foreach ($ctl in $parent.Controls) {
        if ($ctl -is [System.Windows.Forms.ComboBox]) { continue }
        $key = $null
        if ($script:translations.ContainsKey([string]$ctl.Text)) {
            $key = [string]$ctl.Text
        } else {
            foreach ($candidate in $script:translations.Keys) {
                if ([string]$script:translations[$candidate] -ceq [string]$ctl.Text) {
                    $key = [string]$candidate
                    break
                }
            }
        }
        if ($key) {
            if ($null -eq $ctl.Tag) { $ctl.Tag = $key }
            $ctl.Text = T $key
        } elseif ($ctl.Tag -is [string] -and $script:translations.ContainsKey([string]$ctl.Tag)) {
            # Do not overwrite dynamic status or path information with its initial caption.
            $original = [string]$ctl.Tag
            $translated = [string]$script:translations[$original]
            if ($ctl.Text -ceq $original -or $ctl.Text -ceq $translated) {
                $ctl.Text = T $original
            }
        }
        if ($ctl.Controls.Count -gt 0) { Localize-Controls $ctl }
    }
}
function Set-ComboItems($combo, [string[]]$ru, [string[]]$en) {
    $idx = $combo.SelectedIndex
    $combo.BeginUpdate()
    try {
        $combo.Items.Clear()
        $items = if ($script:language -eq 'en') { $en } else { $ru }
        $combo.Items.AddRange([object[]]$items)
        $combo.SelectedIndex = [Math]::Max(0, [Math]::Min($items.Length - 1, $idx))
    } finally { $combo.EndUpdate() }
}
function Apply-Language([string]$language) {
    if ($script:languageChanging) { return }
    $script:languageChanging = $true
    try {
        $script:language = if ($language -eq 'en') { 'en' } else { 'ru' }
        Localize-Controls $form
        Set-ComboItems $cmbAlg @('XPRESS 4K — быстро, слабое сжатие', 'XPRESS 8K — стандарт', 'XPRESS 16K — сильнее', 'LZX — максимум (рекомендую для игр)') @('XPRESS 4K — fastest, lower compression', 'XPRESS 8K — balanced', 'XPRESS 16K — stronger compression', 'LZX — maximum (recommended for games)')
        Set-ComboItems $cmbCpu @('Самый низкий (Idle)', 'Ниже обычного', 'Обычный') @('Lowest (Idle)', 'Below normal', 'Normal')
        Set-ComboItems $cmbIo @('Очень низкий', 'Низкий', 'Обычный') @('Very low', 'Low', 'Normal')
        $cmbLanguage.SelectedIndex = if ($script:language -eq 'en') { 1 } else { 0 }
        $form.Text = "Zipper $($script:Version) — Compact OS"
        Update-Load
        Update-DriveInfo
    } finally { $script:languageChanging = $false }
}

# ---------------------------------------------------------------- лог в окне
function Add-Log([string]$text, $color = $null) {
    if (-not $color) { $color = $cMuted }
    if ($rtb.TextLength -gt 120000) { $rtb.Select(0, 60000); $rtb.SelectedText = '' }
    $rtb.SelectionStart = $rtb.TextLength
    $rtb.SelectionLength = 0
    $rtb.SelectionColor = $color
    $rtb.AppendText($text + "`r`n")
    $rtb.SelectionColor = $rtb.ForeColor
    $rtb.ScrollToCaret()
    Write-LogFile $text
}

function Write-EngineLog([string]$ln) {
    if ($ln.Length -lt 3) { return }
    $kind = $ln.Substring(0, 1)
    $msg = $ln.Substring(2)
    if ($kind -eq 'E') { Add-Log $msg $cRed }
    elseif ($kind -eq 'W') { Add-Log $msg $cYellow }
    else { Add-Log $msg $cMuted }
}

# ---------------------------------------------------------------- диск: тип и файловая система
$script:mediaCache = @{}
function Get-MediaType([string]$letter) {
    if ($script:mediaCache.ContainsKey($letter)) { return $script:mediaCache[$letter] }
    $m = ''
    try {
        $num = (Get-Partition -DriveLetter $letter -ErrorAction Stop).DiskNumber
        $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$num } | Select-Object -First 1
        if ($pd) {
            $m = [string]$pd.MediaType
            if ([string]$pd.BusType -eq 'NVMe') { $m = 'NVMe SSD' }
            if ($m -eq 'Unspecified') { $m = '' }
        }
    } catch {}
    $script:mediaCache[$letter] = $m
    return $m
}

function Update-DriveInfo {
    $p = $txtPath.Text.Trim().Trim('"')
    $lblInfo.ForeColor = $cMuted
    if ([string]::IsNullOrWhiteSpace($p)) { $lblInfo.Text = T 'Выбери папку с игрой или программой (можно перетащить её в окно).'; return }
    try {
        $full = [System.IO.Path]::GetFullPath($p)
        $root = [System.IO.Path]::GetPathRoot($full)
        if ($root.StartsWith('\\')) {
            $lblInfo.Text = T 'Сетевой путь: Compact OS на сетевых папках не работает.'
            $lblInfo.ForeColor = $cRed
            return
        }
        $letter = $root.Substring(0, 1)
        $di = New-Object System.IO.DriveInfo($letter)
        $media = Get-MediaType $letter
        $txt = (T 'Диск {0}: · {1}') -f $letter.ToUpper(), $di.DriveFormat
        if ($media) { $txt += ' · ' + $media }
        $txt += (T ' · свободно ') + (Fmt-Bytes $di.AvailableFreeSpace)
        if ($di.DriveFormat -ne 'NTFS') {
            $txt += T ' — Compact OS работает только на NTFS!'
            $lblInfo.ForeColor = $cRed
        } elseif ($media -eq 'HDD') {
            $txt += T ' — на HDD лучше 1–2 потока'
            $lblInfo.ForeColor = $cYellow
        }
        $lblInfo.Text = $txt
    } catch {
        $lblInfo.Text = ''
    }
}

# ---------------------------------------------------------------- применение настроек нагрузки
function Update-Load {
    $engine.Threads = $tbThreads.Value
    $engine.CpuPriority = $cmbCpu.SelectedIndex
    $engine.IoPriority = $cmbIo.SelectedIndex
    $engine.LoadPercent = $tbLoad.Value * 5
    $lblThreads.Text = (T '{0} из {1}') -f $tbThreads.Value, $cores
    $pct = $tbLoad.Value * 5
    if ($pct -ge 100) { $lblLoad.Text = T '100% — без пауз' } else { $lblLoad.Text = (T '{0}% — с паузами') -f $pct }
}

function Set-Preset([string]$name) {
    if ($name -eq 'quiet') {
        $tbThreads.Value = 1; $cmbCpu.SelectedIndex = 0; $cmbIo.SelectedIndex = 0; $tbLoad.Value = 10
    } elseif ($name -eq 'balanced') {
        $tbThreads.Value = [Math]::Max(1, [int][Math]::Floor($cores / 2)); $cmbCpu.SelectedIndex = 1; $cmbIo.SelectedIndex = 1; $tbLoad.Value = 20
    } else {
        $tbThreads.Value = $cores; $cmbCpu.SelectedIndex = 2; $cmbIo.SelectedIndex = 2; $tbLoad.Value = 20
    }
    Update-Load
}

# ---------------------------------------------------------------- проверка выбранной папки
function Test-Target([string]$p) {
    $r = @{ Ok = $false; Msg = ''; Warn = '' }
    if ([string]::IsNullOrWhiteSpace($p)) { $r.Msg = T 'Сначала выбери папку.'; return $r }
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { $r.Msg = T 'Такой папки нет.'; return $r }
    $full = [System.IO.Path]::GetFullPath($p)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($root.StartsWith('\\')) { $r.Msg = T 'Сетевые пути не поддерживаются: Compact OS работает только на локальном NTFS.'; return $r }
    try { $di = New-Object System.IO.DriveInfo($root.Substring(0, 1)) } catch { $r.Msg = T 'Не удалось определить диск.'; return $r }
    if ($di.DriveType -eq 'Network') { $r.Msg = T 'Сетевые диски не поддерживаются.'; return $r }
    if ($di.DriveFormat -ne 'NTFS') {
        $r.Msg = (T 'Диск {0} отформатирован в {1}. Compact OS работает только на NTFS.') -f $root.Substring(0, 2), $di.DriveFormat
        return $r
    }
    $t = $full.TrimEnd('\')
    $sysRoot = $env:SystemRoot.TrimEnd('\')
    if ($t -ieq $sysRoot -or $t.StartsWith($sysRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $r.Msg = T 'Папку Windows сжимать нельзя — система может перестать загружаться.'
        return $r
    }
    if ($t -ieq $env:SystemDrive) {
        $r.Msg = T 'Корень системного диска сжимать нельзя (там Windows). Выбери конкретную папку с игрой или программой.'
        return $r
    }
    if ($t.Length -le 2) {
        $r.Warn = (T 'Выбран корень диска {0} — будет сжато вообще всё на нём. Продолжить?') -f $t
    } else {
        foreach ($d in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:USERPROFILE)) {
            if ($d -and ($t -ieq $d.TrimEnd('\'))) {
                $r.Warn = (T 'Это системная папка ({0}): там много файлов, которые постоянно используются. Лучше выбрать конкретную подпапку. Всё равно продолжить?') -f $t
            }
        }
    }
    $r.Ok = $true
    return $r
}

# ---------------------------------------------------------------- запуск
$script:lastState = 0
$script:speed = 0.0
$script:prevBytes = 0
$script:clock = [System.Diagnostics.Stopwatch]::StartNew()
$script:prevTick = 0
$script:modeText = ''

function Set-Running([bool]$on) {
    $btnCompress.Enabled = -not $on
    $btnDecompress.Enabled = -not $on
    $btnAnalyze.Enabled = -not $on
    $btnPause.Enabled = $on
    $btnStop.Enabled = $on
    $txtPath.Enabled = -not $on
    $btnBrowse.Enabled = -not $on
    $cmbAlg.Enabled = -not $on
    $chkForce.Enabled = -not $on
    $chkMedia.Enabled = -not $on
    if (-not $on) {
        $btnPause.Text = T 'Пауза'
        $btnStop.Text = T 'Стоп'
        $form.Text = "Zipper $($script:Version) — Compact OS"
    }
}

function Start-Zipper([bool]$decompress, [bool]$analyze) {
    if ($engine.Busy) { return }
    $p = $txtPath.Text.Trim().Trim('"')
    $chk = Test-Target $p
    if (-not $chk.Ok) {
        [System.Windows.Forms.MessageBox]::Show($chk.Msg, 'Zipper', 'OK', 'Warning') | Out-Null
        return
    }
    if ($chk.Warn -and -not $analyze) {
        $ans = [System.Windows.Forms.MessageBox]::Show($chk.Warn, 'Zipper', 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { return }
    }
    $keys = 'xpress4k', 'xpress8k', 'xpress16k', 'lzx'
    $names = 'XPRESS 4K', 'XPRESS 8K', 'XPRESS 16K', 'LZX'
    $engine.Algorithm = $keys[$cmbAlg.SelectedIndex]
    $engine.Decompress = $decompress
    $engine.Force = $chkForce.Checked
    $engine.SkipMedia = $chkMedia.Checked
    Update-Load
    if ($analyze) { $script:modeText = T 'Анализ' }
    elseif ($decompress) { $script:modeText = T 'Расжатие' }
    else { $script:modeText = (T 'Сжатие ') + $names[$cmbAlg.SelectedIndex] }
    Add-Log ('— {0}: {1}' -f $script:modeText, $p) $cAccent
    $script:speed = 0.0
    $script:prevBytes = 0
    $script:prevTick = $script:clock.ElapsedMilliseconds
    Set-Bar $barMain 0
    $lblStat2.Text = ''
    if (-not $engine.Begin($p, $analyze)) { return }
    Set-Running $true
}

function Show-StateSummary([int]$st) {
    if ($st -eq 5) {
        $all = [double]$engine.AllBytes
        $disk = [double]$engine.AllDisk
        $ratio = 0.0
        if ($all -gt 0) { $ratio = [Math]::Max(0.0, 100.0 * (1.0 - $disk / $all)) }
        Add-Log ((T 'Файлов: {0:N0}, объём {1}, на диске {2} (уже сэкономлено {3:N0}%)') -f $engine.AllFiles, (Fmt-Bytes $all), (Fmt-Bytes $disk), $ratio) $cText
        Add-Log ((T 'Можно сжать: {0:N0} файлов, {1}') -f $engine.SelFiles, (Fmt-Bytes $engine.SelBytes)) $cGreen
        $lblStat1.Text = T 'Анализ завершён.'
        $lblStat2.Text = ''
        Set-Bar $barMain 0
    } elseif ($st -eq 3) {
        if ($engine.SelFiles -eq 0) {
            Add-Log (T 'Нечего делать: подходящих файлов нет (всё уже обработано или файлы слишком мелкие / исключены).') $cYellow
            $lblStat1.Text = T 'Нечего делать.'
            Set-Bar $barMain 0
        } else {
            $saved = [double]$engine.DiskDelta
            $pct = 0.0
            if ($engine.SelDisk -gt 0) { $pct = 100.0 * $saved / [double]$engine.SelDisk }
            $time = Fmt-Time ($engine.ElapsedMs / 1000.0)
            if ($engine.Decompress) {
                Add-Log ((T 'Готово за {0}. Занято дополнительно: {1}. OK: {2:N0}, ошибок: {3:N0}') -f $time, (Fmt-Bytes ([Math]::Abs($saved))), $engine.OkCount, $engine.ErrCount) $cGreen
            } else {
                Add-Log ((T 'Готово за {0}. Освобождено: {1} ({2:N1}%). OK: {3:N0}, ошибок: {4:N0}') -f $time, (Fmt-Bytes $saved), $pct, $engine.OkCount, $engine.ErrCount) $cGreen
            }
            $lblStat1.Text = T 'Готово.'
            Set-Bar $barMain 1
            try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
        }
    } elseif ($st -eq 4) {
        Add-Log ((T 'Остановлено. Обработано файлов: {0:N0} из {1:N0}.') -f $engine.DoneFiles, $engine.SelFiles) $cYellow
        $lblStat1.Text = T 'Остановлено.'
    } elseif ($st -eq 6) {
        Add-Log ((T 'Ошибка: ') + $engine.LastError) $cRed
        $lblStat1.Text = T 'Ошибка.'
    }
}

function Update-UI {
    foreach ($ln in $engine.DrainLog(300)) { Write-EngineLog $ln }

    # живая загрузка системы
    if ($script:pcOk) {
        try {
            $cpu = [Math]::Min(100.0, [Math]::Max(0.0, [double]$script:pcCpu.NextValue()))
            $dsk = [Math]::Min(100.0, [Math]::Max(0.0, 100.0 - [double]$script:pcDisk.NextValue()))
            $lblCpuTxt.Text = 'CPU {0:N0}%' -f $cpu
            $lblDskTxt.Text = (T 'Диск {0:N0}%') -f $dsk
            $cc = $cGreen; if ($cpu -ge 85) { $cc = $cRed } elseif ($cpu -ge 60) { $cc = $cYellow }
            $dc = $cGreen; if ($dsk -ge 85) { $dc = $cRed } elseif ($dsk -ge 60) { $dc = $cYellow }
            Set-Bar $barCpu ($cpu / 100.0) $cc
            Set-Bar $barDsk ($dsk / 100.0) $dc
        } catch { $script:pcOk = $false }
    }

    $st = [int]$engine.State
    if ($st -ne $script:lastState) {
        $old = $script:lastState
        $script:lastState = $st
        if ($st -eq 2 -and $old -ne 2) {
            Add-Log ((T 'В папке файлов: {0:N0} ({1}). К обработке: {2:N0} ({3}).') -f $engine.AllFiles, (Fmt-Bytes $engine.AllBytes), $engine.SelFiles, (Fmt-Bytes $engine.SelBytes)) $cText
        }
        if ($st -ge 3) {
            Set-Running $false
            Show-StateSummary $st
        }
    }

    if ($st -eq 1) {
        $lblStat1.Text = (T 'Сканирование… файлов: {0:N0}') -f $engine.Scanned
    } elseif ($st -eq 2) {
        $tot = [double]$engine.SelBytes
        $done = [double]$engine.DoneBytes
        $r = 0.0
        if ($tot -gt 0) { $r = $done / $tot }
        Set-Bar $barMain $r

        $now = $script:clock.ElapsedMilliseconds
        $dt = ($now - $script:prevTick) / 1000.0
        if ($dt -gt 0.2) {
            $inst = ($done - $script:prevBytes) / $dt
            $script:speed = 0.85 * $script:speed + 0.15 * $inst
            $script:prevBytes = $done
            $script:prevTick = $now
        }
        $eta = [double]::PositiveInfinity
        if ($script:speed -gt 1024) { $eta = ($tot - $done) / $script:speed }
        $state = ''
        if ($engine.Paused) { $state = T '   [ПАУЗА]' }
        $lblStat1.Text = ((T 'Файлов: {0:N0} / {1:N0}    Данные: {2} / {3}    Скорость: {4}/с    Осталось: {5}{6}') -f $engine.DoneFiles, $engine.SelFiles, (Fmt-Bytes $done), (Fmt-Bytes $tot), (Fmt-Bytes $script:speed), (Fmt-Time $eta), $state)
        $saved = [double]$engine.DiskDelta
        $lblStat2.Text = ((T 'OK: {0:N0}    Ошибок: {1:N0}    Освобождено на диске: {2}') -f $engine.OkCount, $engine.ErrCount, (Fmt-Bytes $saved))
        $form.Text = ('{0:N0}% — Zipper {1}' -f ($r * 100), $script:Version)
    }
}

# ---------------------------------------------------------------- события
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = T 'Выбери папку для сжатия'
    $dlg.ShowNewFolderButton = $false
    if ($txtPath.Text -and (Test-Path -LiteralPath $txtPath.Text.Trim().Trim('"') -PathType Container)) { $dlg.SelectedPath = $txtPath.Text.Trim().Trim('"') }
    if ($dlg.ShowDialog() -eq 'OK') { $txtPath.Text = $dlg.SelectedPath; Update-DriveInfo }
})
$txtPath.Add_Leave({ Update-DriveInfo })
$form.Add_Dropped({
    $p = $form.DroppedPath
    if ($p) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { $p = Split-Path -Parent $p }
        $txtPath.Text = $p
        Update-DriveInfo
    }
})

$tbThreads.Add_ValueChanged({ Update-Load })
$tbLoad.Add_ValueChanged({ Update-Load })
$cmbCpu.Add_SelectedIndexChanged({ Update-Load })
$cmbIo.Add_SelectedIndexChanged({ Update-Load })
$btnQuiet.Add_Click({ Set-Preset 'quiet' })
$btnBal.Add_Click({ Set-Preset 'balanced' })
$btnMax.Add_Click({ Set-Preset 'max' })

$btnCompress.Add_Click({ Start-Zipper $false $false })
$btnDecompress.Add_Click({ Start-Zipper $true $false })
$btnAnalyze.Add_Click({ Start-Zipper $false $true })

$btnPause.Add_Click({
    $engine.Paused = -not $engine.Paused
    if ($engine.Paused) { $btnPause.Text = T 'Продолжить' } else { $btnPause.Text = 'Пауза' }
})
$btnStop.Add_Click({
    if (-not $engine.Busy) { return }
    $engine.Stop()
    if ($engine.StopCount -ge 2) {
        Add-Log (T 'Прервано принудительно.') $cYellow
    } else {
        $btnStop.Text = T 'Прервать'
        Add-Log (T 'Останавливаю: дожидаюсь завершения текущих файлов… Повторное нажатие прервёт сразу.') $cYellow
    }
})
$cmbLanguage.Add_SelectedIndexChanged({
    if ($script:languageChanging) { return }
    if ($cmbLanguage.SelectedIndex -eq 1) { Apply-Language 'en' } else { Apply-Language 'ru' }
})

$btnLogOpen.Add_Click({
    try {
        if (Test-Path -LiteralPath $script:logFile) { Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $script:logFile) }
        else { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $script:dataDir) }
    } catch {}
})

$form.Add_Shown({
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if ($form.Height -gt $wa.Height) { $form.Height = $wa.Height; $form.Top = $wa.Top }
})

$form.Add_FormClosing({
    param($sender, $e)
    if ($engine.Busy) {
        $ans = [System.Windows.Forms.MessageBox]::Show((T 'Идёт работа. Прервать и выйти?'), 'Zipper', 'YesNo', 'Question')
        if ($ans -ne 'Yes') { $e.Cancel = $true; return }
        $engine.Stop(); $engine.Stop()
    }
    try {
        $o = [ordered]@{
            threads = $tbThreads.Value; cpu = $cmbCpu.SelectedIndex; io = $cmbIo.SelectedIndex; load = $tbLoad.Value
            alg = $cmbAlg.SelectedIndex; force = $chkForce.Checked; media = $chkMedia.Checked; path = $txtPath.Text; language = $script:language
        }
        ($o | ConvertTo-Json) | Set-Content -LiteralPath $script:settingsFile -Encoding UTF8
    } catch {}
})

# ---------------------------------------------------------------- счётчики загрузки системы
$script:pcOk = $false
try {
    $script:pcCpu = New-Object System.Diagnostics.PerformanceCounter('Processor', '% Processor Time', '_Total')
    $script:pcDisk = New-Object System.Diagnostics.PerformanceCounter('PhysicalDisk', '% Idle Time', '_Total')
    $null = $script:pcCpu.NextValue(); $null = $script:pcDisk.NextValue()
    $script:pcOk = $true
} catch {
    $lblCpuTxt.Text = ''; $lblDskTxt.Text = ''
}

# ---------------------------------------------------------------- старт
Set-Preset 'balanced'
if ($settings) {
    try {
        if ($null -ne $settings.threads) { $tbThreads.Value = [Math]::Max(1, [Math]::Min($cores, [int]$settings.threads)) }
        if ($null -ne $settings.cpu) { $cmbCpu.SelectedIndex = [Math]::Max(0, [Math]::Min(2, [int]$settings.cpu)) }
        if ($null -ne $settings.io) { $cmbIo.SelectedIndex = [Math]::Max(0, [Math]::Min(2, [int]$settings.io)) }
        if ($null -ne $settings.load) { $tbLoad.Value = [Math]::Max(1, [Math]::Min(20, [int]$settings.load)) }
        if ($null -ne $settings.alg) { $cmbAlg.SelectedIndex = [Math]::Max(0, [Math]::Min(3, [int]$settings.alg)) }
        if ($null -ne $settings.force) { $chkForce.Checked = [bool]$settings.force }
        if ($null -ne $settings.media) { $chkMedia.Checked = [bool]$settings.media }
        if ($settings.path) { $txtPath.Text = [string]$settings.path }
    } catch {}
}
if ($env:ZIPPER_ARG) {
    $a = $env:ZIPPER_ARG.Trim().Trim('"')
    if ($a) {
        if (Test-Path -LiteralPath $a -PathType Leaf) { $a = Split-Path -Parent $a }
        $txtPath.Text = $a
    }
}
Apply-Language $script:language
Update-Load
Update-DriveInfo

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    try { Update-UI } catch { Write-LogFile ('UI: ' + $_.Exception.Message) }
})
$timer.Start()

try {
    [System.Windows.Forms.Application]::Run($form)
} catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.ToString(), 'Zipper — ошибка', 'OK', 'Error') | Out-Null
} finally {
    $timer.Stop()
    if ($engine.Busy) { $engine.Stop(); $engine.Stop() }
}
