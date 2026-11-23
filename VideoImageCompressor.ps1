#Requires -Version 5.1
<#
  Video and Image Compressor GUI v2.2.0
  Compress a video OR an image to a target file size.
   VIDEO (ffmpeg): MP4, MKV, MOV (H.264 + AAC) or WebM (VP9 + Opus).
                   Auto-detects a GPU encoder (NVIDIA / Intel / AMD), falls back to the CPU.
   IMAGE (ImageMagick / CaesiumCLT): JPG, WebP or PNG. Select the image engine in the GUI.
                   ImageMagick uses adaptive quality and resolution search, PNG optimization and ICC handling.
                   CaesiumCLT uses native target-size compression and lossless PNG optimization.
  Strict split: ffmpeg/ffprobe are only used on videos; both image engines are only used on images.
  Needs ffmpeg.exe + ffprobe.exe next to this script (or in PATH).
  Image mode needs either imagemagick\magick.exe or caesium\caesiumclt.exe (v1.5.0 or newer).
  NOTE: keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI).
#>

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# =====================================================================
# 1. CONFIG
# =====================================================================
$script:AppName = 'Video and Image Compressor'
$script:AppVer  = '2.2.0'
$script:Cfg = @{
    MaxMB          = 10000  # largest accepted target size
    MarginCpu      = 0.95   # 2-pass x264/VP9 is accurate -> 5% safety margin
    MarginGpu      = 0.92   # 1-pass GPU VBR is looser -> 8% safety margin
    MinVideoKbps   = 50     # below this the video target is refused
    LowQualityKbps = 300    # below this the user is warned
    TimerMs        = 500    # video progress polling interval
    ImageTimerMs   = 150    # each image attempt is short, so poll faster
    ImgQualityMax  = 95     # first quality tried
    ImgQualityMin  = 45     # below this the picture is shrunk instead of degraded further
    ImgScaleMin    = 20     # minimum permitted resolution percentage
    ImgScaleMargin = 0.98   # safety margin when estimating resolution
    CaesiumPngOpt  = 6      # lossless PNG optimization level (0-6)
    ErrorLogMax    = 5MB    # maximum size of each new error log
    ErrorLogKeep   = 3      # number of rotated error logs to retain
}
$script:AppData = Join-Path $env:LOCALAPPDATA 'VideoImageCompressor'
$script:ErrLog  = Join-Path $script:AppData 'error.log'

# Accepted input types by compression engine.
$script:VideoExts = @('.mp4', '.mkv', '.mov', '.avi', '.wmv', '.webm', '.flv', '.m4v')
$script:ImageExts = @{ '.jpg' = 'JPEG'; '.jpeg' = 'JPEG'; '.png' = 'PNG'; '.webp' = 'WEBP'; '.bmp' = 'BMP'; '.tif' = 'TIFF'; '.tiff' = 'TIFF' }
$script:CaesiumExts = @('.jpg', '.jpeg', '.png', '.webp')   # tested input formats

# Encoder table. Opts are the same options used for the real encode AND for the detection test.
$script:Encoders = @(
    @{ Id = 'h264_nvenc'; Name = 'NVIDIA NVENC (GPU)';     Gpu = $true; Opts = '-preset p5 -tune hq -rc vbr' },
    @{ Id = 'h264_qsv';   Name = 'Intel Quick Sync (GPU)'; Gpu = $true; Opts = '-preset slow' },
    @{ Id = 'h264_amf';   Name = 'AMD AMF (GPU)';          Gpu = $true; Opts = '-quality quality -rc vbr_peak' }
)
$script:CpuEncoder = @{ Id = 'libx264';    Name = 'CPU (x264)'; Gpu = $false; Opts = '-preset medium' }
$script:Vp9Encoder = @{ Id = 'libvpx-vp9'; Name = 'CPU (VP9)';  Gpu = $false; Opts = '-deadline good -cpu-used 4 -row-mt 1' }

# Output formats. Kind picks the codec path: h264 = x264/GPU + AAC, vp9 = VP9 + Opus (WebM cannot hold H.264).
$script:Formats = @(
    @{ Name = 'MP4  - H.264 + AAC (most compatible)'; Ext = '.mp4';  Muxer = 'mp4';      Kind = 'h264'; Flags = '-movflags +faststart' },
    @{ Name = 'MKV  - H.264 + AAC';                   Ext = '.mkv';  Muxer = 'matroska'; Kind = 'h264'; Flags = '' },
    @{ Name = 'MOV  - H.264 + AAC (Apple / editors)'; Ext = '.mov';  Muxer = 'mov';      Kind = 'h264'; Flags = '-movflags +faststart' },
    @{ Name = 'WebM - VP9 + Opus (CPU only, slower)'; Ext = '.webm'; Muxer = 'webm';     Kind = 'vp9';  Flags = '' }
)

# Image output formats. JPG/WebP use quality search; PNG uses lossless optimization and resizing.
$script:ImageFormats = @(
    @{ Name = 'JPG  - best for photos (small, works everywhere)'; Ext = '.jpg';  Kind = 'jpg';  Coder = 'JPEG' },
    @{ Name = 'WebP - smaller than JPG (modern apps and web)';    Ext = '.webp'; Kind = 'webp'; Coder = 'WEBP' },
    @{ Name = 'PNG  - lossless (resize if needed)';             Ext = '.png';  Kind = 'png';  Coder = 'PNG' }
)

# =====================================================================
# 2. ERROR HANDLING + TOOL LOOKUP
# =====================================================================
# ---- 2A. Error reporting and bounded log rotation ----
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)

function Show-Msg([string]$text, [string]$title = $script:AppName, [string]$buttons = 'OK', [string]$icon = 'Information') {
    return [System.Windows.Forms.MessageBox]::Show($text, $title, $buttons, $icon)
}

function Rotate-ErrorLog {
    # Check every destination before altering any log; never follow links.
    for ($i = 0; $i -le $script:Cfg.ErrorLogKeep; $i++) {
        $path = if ($i -eq 0) { $script:ErrLog } else { "$($script:ErrLog).$i" }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
            throw 'Unsafe error log path.'
        }
    }
    $oldest = "$($script:ErrLog).$($script:Cfg.ErrorLogKeep)"
    if ([IO.File]::Exists($oldest)) { Remove-Item -LiteralPath $oldest -Force -ErrorAction Stop }
    for ($i = $script:Cfg.ErrorLogKeep - 1; $i -ge 1; $i--) {
        $from = "$($script:ErrLog).$i"
        if ([IO.File]::Exists($from)) { Move-Item -LiteralPath $from -Destination "$($script:ErrLog).$($i + 1)" -ErrorAction Stop }
    }
    if ([IO.File]::Exists($script:ErrLog)) { Move-Item -LiteralPath $script:ErrLog -Destination "$($script:ErrLog).1" -ErrorAction Stop }
}

function Write-ErrorLog([string]$msg) {
    $mutex = $null; $locked = $false
    try {
        # Serialize rotation across app instances in the same Windows session.
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $mutex = New-Object System.Threading.Mutex($false, "Local\VideoImageCompressor.ErrorLog.$sid")
        try { $locked = $mutex.WaitOne(1000) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { return }
        [void][IO.Directory]::CreateDirectory($script:AppData)
        $dir = Get-Item -LiteralPath $script:AppData -Force -ErrorAction Stop
        if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
        $item = Get-Item -LiteralPath $script:ErrLog -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))) { return }

        $encoding = New-Object System.Text.UTF8Encoding($false)
        $entry = "[{0}] {1}`r`n" -f (Get-Date -Format 's'), $msg
        # Truncate exceptionally large entries so one error cannot fill a log.
        if ($encoding.GetByteCount($entry) -gt $script:Cfg.ErrorLogMax) {
            $limit = [int][math]::Floor(($script:Cfg.ErrorLogMax - 64) / 4)
            $entry = $entry.Substring(0, $limit) + " [truncated]`r`n"
        }
        $size = if ($item) { $item.Length } else { 0 }
        if ($size + $encoding.GetByteCount($entry) -gt $script:Cfg.ErrorLogMax) { Rotate-ErrorLog }
        [IO.File]::AppendAllText($script:ErrLog, $entry, $encoding)
    } catch {}
    finally {
        if ($locked) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
}

# The console is hidden when launched from the shortcut, so errors must be shown in a dialog.
function Show-Fatal([string]$msg) {
    Write-ErrorLog $msg
    [void](Show-Msg ($msg + "`n`nDetails: " + $script:ErrLog) "$($script:AppName) - Error" 'OK' 'Error')
}

# Safety net: an unexpected UI error gets a friendly dialog + log entry instead of the raw .NET crash box.
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    Write-ErrorLog $e.Exception.ToString()
    [void](Show-Msg ("Unexpected error:`n" + $e.Exception.Message + "`n`nDetails: " + $script:ErrLog) 'Error' 'OK' 'Error')
})

# ---- 2B. Compression engine discovery ----
function Find-Tool([string]$name, [string]$subDir = '') {
    $dirs = @()
    if ($PSScriptRoot) {
        if ($subDir) { $dirs += (Join-Path $PSScriptRoot $subDir) }
        $dirs += $PSScriptRoot
    }
    foreach ($d in $dirs) {
        $p = Join-Path $d "$name.exe"
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

$script:ffmpeg  = Find-Tool 'ffmpeg'
$script:ffprobe = Find-Tool 'ffprobe'
if (-not $script:ffmpeg -or -not $script:ffprobe) {
    Show-Fatal "ffmpeg.exe / ffprobe.exe not found.`n`nReinstall Video and Image Compressor, or place both files in the same folder as VideoImageCompressor.ps1."
    return
}
# Image engines are independently optional; at least one enables Image mode.
$script:magick = Find-Tool 'magick' 'imagemagick'
$script:caesium = Find-Tool 'caesiumclt' 'caesium'
$script:caesiumUnavailable = ''
if ($script:caesium) {
    try {
        $versionText = [string](& $script:caesium --version 2>$null | Select-Object -First 1)
        if ($versionText -notmatch '(\d+\.\d+\.\d+)' -or [version]$Matches[1] -lt [version]'1.5.0') {
            throw 'CaesiumCLT 1.5.0 or newer is required.'
        }
    } catch {
        $script:caesiumUnavailable = $_.Exception.Message
        $script:caesium = $null
    }
}
$script:ImageEngines = @()
if ($script:magick)  { $script:ImageEngines += 'ImageMagick' }
if ($script:caesium) { $script:ImageEngines += 'CaesiumCLT' }

# =====================================================================
# 3. STATE
# =====================================================================
$script:detected    = $script:CpuEncoder   # replaced after the window opens
$script:enc         = $script:CpuEncoder
$script:fmt         = $script:Formats[0]
$script:mode        = 'video'              # 'video' | 'image'
$script:modeLock    = $false               # true while Set-Mode updates the radio buttons
$script:busy        = $false
$script:proc        = $null
$script:inFile      = ''
$script:outFile     = ''
$script:outTmp      = ''                   # unique sibling .part file, published only on success
$script:outOverwrite = $false             # existing output may be replaced only with confirmation
$script:targetBytes = [long]0
$script:batchFiles = @()
$script:batchJobs = @()
$script:batchActive = $false
$script:batchIndex = 0
$script:batchSuccess = 0
$script:batchFailed = 0
$script:batchPending = $false
$script:batchCancelled = $false
$script:selectionLock = $false

# video run
$script:pass        = 0
$script:totalPasses = 2
$script:margin      = $script:Cfg.MarginCpu
$script:duration    = 0.0
$script:vkbps       = 0
$script:akbps       = 128
$script:scale       = $false

# image run
$script:imageEngine = 'ImageMagick'       # selected engine for the current run
$script:img         = $null                # search state (see Step-ImageSearch)
$script:imgSrc      = ''                   # private copy of the input inside the work folder
$script:imgTry      = ''                   # current attempt
$script:imgBest     = ''                   # best attempt that fit the target
$script:maxPx       = 0
$script:strip       = $true

# info-line caches (the info line refreshes on every keystroke)
$script:durPath     = ''
$script:durVal      = 0.0
$script:dimPath     = ''
$script:dimVal      = ''
$script:InfoDefault = 'Pick a file to begin'

# Per-run paths are allocated after all user confirmations.
$script:workDir     = ''
$script:logBase     = ''
$script:progFile    = ''
$script:errFile     = ''

# =====================================================================
# 4. UI (controls only, behaviour is wired up in section 10)
# =====================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text            = "$($script:AppName) $($script:AppVer)"
$form.Size            = New-Object System.Drawing.Size(620, 535)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false

function New-Label($text, $x, $y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.AutoSize = $true
    $l.UseMnemonic = $false   # show '&' literally
    $form.Controls.Add($l)
    return $l
}

# ---- mode ----
[void](New-Label 'Mode:' 15 15)
$rbVideo = New-Object System.Windows.Forms.RadioButton
$rbVideo.Text = 'Video'; $rbVideo.Location = '70,12'; $rbVideo.AutoSize = $true; $rbVideo.Checked = $true
$form.Controls.Add($rbVideo)
$rbImage = New-Object System.Windows.Forms.RadioButton
$rbImage.Text = 'Image'; $rbImage.Location = '150,12'; $rbImage.AutoSize = $true
$form.Controls.Add($rbImage)

# ---- files ----
[void](New-Label 'Input files (select or drop multiple files):' 15 45)
$txtIn = New-Object System.Windows.Forms.TextBox
$txtIn.Location = '15,65'; $txtIn.Size = '480,23'; $txtIn.AllowDrop = $true
$form.Controls.Add($txtIn)
$btnIn = New-Object System.Windows.Forms.Button
$btnIn.Text = 'Browse...'; $btnIn.Location = '505,63'; $btnIn.Size = '85,27'
$form.Controls.Add($btnIn)

$lblOut = New-Label 'Output file:' 15 100
$txtOut = New-Object System.Windows.Forms.TextBox
$txtOut.Location = '15,120'; $txtOut.Size = '480,23'
$form.Controls.Add($txtOut)
$btnOut = New-Object System.Windows.Forms.Button
$btnOut.Text = 'Save as...'; $btnOut.Location = '505,118'; $btnOut.Size = '85,27'
$form.Controls.Add($btnOut)

# ---- target size + format ----
$lblTarget = New-Label 'Target size:' 15 160
$txtMB = New-Object System.Windows.Forms.TextBox
$txtMB.Location = '95,157'; $txtMB.Size = '70,23'; $txtMB.MaxLength = 8   # starts empty on purpose
$form.Controls.Add($txtMB)
$btnMinus = New-Object System.Windows.Forms.Button
$btnMinus.Text = '-'; $btnMinus.Location = '170,156'; $btnMinus.Size = '24,25'
$form.Controls.Add($btnMinus)
$btnPlus = New-Object System.Windows.Forms.Button
$btnPlus.Text = '+'; $btnPlus.Location = '196,156'; $btnPlus.Size = '24,25'
$form.Controls.Add($btnPlus)
$cmbUnit = New-Object System.Windows.Forms.ComboBox
$cmbUnit.DropDownStyle = 'DropDownList'; $cmbUnit.Location = '226,157'; $cmbUnit.Size = '55,23'
[void]$cmbUnit.Items.Add('MB'); [void]$cmbUnit.Items.Add('KB')
$cmbUnit.SelectedIndex = 0
$form.Controls.Add($cmbUnit)

[void](New-Label 'Format:' 295 160)
$cmbFmt = New-Object System.Windows.Forms.ComboBox
$cmbFmt.DropDownStyle = 'DropDownList'
$cmbFmt.Location = '345,157'; $cmbFmt.Size = '245,23'
foreach ($f in $script:Formats) { [void]$cmbFmt.Items.Add($f.Name) }
$cmbFmt.SelectedIndex = 0
$form.Controls.Add($cmbFmt)

# ---- video-only options ----
$chkScale = New-Object System.Windows.Forms.CheckBox
$chkScale.Text = 'Downscale to 720p (better quality at small sizes)'
$chkScale.Location = '15,192'; $chkScale.AutoSize = $true
$form.Controls.Add($chkScale)

$lblEnc = New-Label 'Encoder: detecting...' 15 224
$chkCpu = New-Object System.Windows.Forms.CheckBox
$chkCpu.Text = 'Force CPU'
$chkCpu.Location = '235,221'; $chkCpu.AutoSize = $true; $chkCpu.Enabled = $false
$form.Controls.Add($chkCpu)

# ---- image-only options (hidden until Image mode) ----
$lblMax = New-Label 'Max width/height in px (optional):' 15 195
$lblMax.Visible = $false
$txtMax = New-Object System.Windows.Forms.TextBox
$txtMax.Location = '230,192'; $txtMax.Size = '60,23'; $txtMax.MaxLength = 5; $txtMax.Visible = $false
$form.Controls.Add($txtMax)
$chkStrip = New-Object System.Windows.Forms.CheckBox
$chkStrip.Text = 'Remove metadata (EXIF, GPS)'
$chkStrip.Location = '305,193'; $chkStrip.AutoSize = $true; $chkStrip.Checked = $true; $chkStrip.Visible = $false
$form.Controls.Add($chkStrip)

# Image engine selector occupies the video encoder row in Image mode.
$lblImageEngine = New-Label 'Image engine:' 15 224
$lblImageEngine.Visible = $false
$cmbImageEngine = New-Object System.Windows.Forms.ComboBox
$cmbImageEngine.DropDownStyle = 'DropDownList'
$cmbImageEngine.Location = '110,221'; $cmbImageEngine.Size = '180,23'
foreach ($name in $script:ImageEngines) { [void]$cmbImageEngine.Items.Add($name) }
if ($cmbImageEngine.Items.Count -gt 0) { $cmbImageEngine.SelectedIndex = 0 }
$cmbImageEngine.Visible = $false
$form.Controls.Add($cmbImageEngine)

# ---- status + actions ----
$lblInfo = New-Label $script:InfoDefault 15 252

$btnGo = New-Object System.Windows.Forms.Button
$btnGo.Text = 'Compress'; $btnGo.Location = '15,277'; $btnGo.Size = '120,32'; $btnGo.Enabled = $false
$form.Controls.Add($btnGo)
$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancel'; $btnCancel.Location = '145,277'; $btnCancel.Size = '90,32'; $btnCancel.Enabled = $false
$form.Controls.Add($btnCancel)

$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Location = '15,322'; $bar.Size = '575,22'; $bar.Minimum = 0; $bar.Maximum = 100
$form.Controls.Add($bar)

$log = New-Object System.Windows.Forms.TextBox
$log.Location = '15,354'; $log.Size = '575,110'
$log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'
$form.Controls.Add($log)

# =====================================================================
# 5. GENERAL HELPERS (used by both modes)
# =====================================================================
function Write-Log([string]$msg) {
    $log.AppendText(("[{0}] {1}`r`n" -f (Get-Date -Format 'HH:mm:ss'), $msg))
}

function Remove-Quiet([string]$path, [switch]$Recurse) {
    if ($path -and (Test-Path -LiteralPath $path)) {
        Remove-Item -LiteralPath $path -Force -Recurse:$Recurse -ErrorAction SilentlyContinue
    }
}

function Format-Bytes([double]$b) {
    if ($b -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:N0} KB' -f ($b / 1KB)) }
    return ('{0} B' -f [int]$b)
}

# 'video', 'image', or $null when the extension is not supported.
function Get-MediaKind([string]$path) {
    $ext = [IO.Path]::GetExtension($path)
    if (-not $ext) { return $null }
    $ext = $ext.ToLowerInvariant()
    if ($script:VideoExts -contains $ext)   { return 'video' }
    if ($script:ImageExts.ContainsKey($ext)) { return 'image' }
    return $null
}

# =====================================================================
# 6. UI STATE HELPERS (read and update the controls)
# =====================================================================
# Target size in bytes from the size box + unit, or 0 when empty/invalid (valid: 1 KB .. MaxMB).
function Get-TargetBytes {
    $n = [long]0
    if ([long]::TryParse($txtMB.Text.Trim(), [ref]$n) -and $n -ge 1) {
        $factor = if ($cmbUnit.SelectedItem -eq 'KB') { 1KB } else { 1MB }
        $bytes  = $n * $factor
        if ($bytes -ge 1KB -and $bytes -le ($script:Cfg.MaxMB * 1MB)) { return [long]$bytes }
    }
    return [long]0
}

function Get-SizeStep {
    if ($cmbUnit.SelectedItem -eq 'KB') { return 50 }
    return 1
}

function Get-FormatList {
    if ($script:mode -eq 'image') { return $script:ImageFormats }
    return $script:Formats
}

function Get-ImageEngine {
    return [string]$cmbImageEngine.SelectedItem
}

function Test-ImageEngineInput([string]$path) {
    if ((Get-ImageEngine) -eq 'CaesiumCLT') {
        return ($script:CaesiumExts -contains [IO.Path]::GetExtension($path).ToLowerInvariant())
    }
    return ($script:magick -and (Get-MediaKind $path) -eq 'image')
}

function Get-Format {
    $list = @(Get-FormatList)
    return $list[[math]::Max(0, [math]::Min($cmbFmt.SelectedIndex, $list.Count - 1))]
}

# Output name next to the input: <name>_compressed<ext>. Only touches the box when the input is a valid file of the current mode.
function Sync-OutputName([bool]$clearIfNone) {
    if ($script:batchFiles.Count -gt 1) { return }
    $path = $txtIn.Text.Trim().Trim('"')
    if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf) -and ((Get-MediaKind $path) -eq $script:mode)) {
        $dir  = Split-Path $path -Parent
        $name = [IO.Path]::GetFileNameWithoutExtension($path)
        $txtOut.Text = Join-Path $dir ($name + '_compressed' + (Get-Format).Ext)
    } elseif ($clearIfNone) {
        $txtOut.Text = ''
    }
}

# Switch the whole window between Video and Image mode.
function Set-Mode([string]$mode) {
    if ($mode -eq 'image' -and $script:ImageEngines.Count -eq 0) {
        [void](Show-Msg "Image mode requires ImageMagick or CaesiumCLT.`n`nPlace magick.exe in imagemagick or caesiumclt.exe in caesium next to this script." 'Image engine not found' 'OK' 'Warning')
        $mode = 'video'
    }
    $changed = ($script:mode -ne $mode)
    $script:mode = $mode
    $script:modeLock = $true
    try {
        $isImg = ($mode -eq 'image')
        $rbVideo.Checked = -not $isImg
        $rbImage.Checked = $isImg

        $cmbFmt.Items.Clear()
        foreach ($f in @(Get-FormatList)) { [void]$cmbFmt.Items.Add($f.Name) }
        $cmbFmt.SelectedIndex = 0
        $cmbUnit.SelectedIndex = if ($isImg) { 1 } else { 0 }     # images are small: default to KB
        if ($changed) { $txtMB.Text = '' }

        $chkScale.Visible = -not $isImg; $lblEnc.Visible = -not $isImg; $chkCpu.Visible = -not $isImg
        $lblMax.Visible   = $isImg;      $txtMax.Visible = $isImg;      $chkStrip.Visible = $isImg
        $lblImageEngine.Visible = $isImg; $cmbImageEngine.Visible = $isImg
        $cmbImageEngine.Enabled = ($isImg -and $script:ImageEngines.Count -gt 1)

        Sync-OutputName $changed
        Update-EncoderUi
    } finally {
        $script:modeLock = $false
    }
    Update-Info
}

function Set-InputFiles([string[]]$paths) {
    $paths = @($paths | Select-Object -Unique)
    if ($paths.Count -eq 0) { return }
    $kind = Get-MediaKind $paths[0]
    foreach ($path in $paths) {
        if (-not $kind -or (Get-MediaKind $path) -ne $kind -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            [void](Show-Msg 'Select only supported files of the same type (all videos or all images).' 'Selection' 'OK' 'Warning'); return
        }
    }
    if ($kind -eq 'image' -and $script:ImageEngines.Count -eq 0) {
        [void](Show-Msg 'No image compression engine is installed.' 'Selection' 'OK' 'Warning'); return
    }
    $script:batchFiles = $paths
    $script:durPath = ''; $script:durVal = 0.0
    $script:dimPath = ''; $script:dimVal = ''
    $script:selectionLock = $true
    try {
        $multi = $paths.Count -gt 1
        $txtIn.ReadOnly = $multi
        $lblOut.Text = if ($multi) { 'Output folder (blank = original folders):' } else { 'Output file:' }
        $btnOut.Text = if ($multi) { 'Folder...' } else { 'Save as...' }
        $lblTarget.Text = if ($multi) { 'Each file:' } else { 'Target size:' }
        $txtIn.Text = if ($multi) { "$($paths.Count) files: " + (($paths | ForEach-Object { [IO.Path]::GetFileName($_) }) -join '; ') } else { $paths[0] }
        if ($multi) { $txtOut.Text = '' }
        if ($kind -ne $script:mode) { Set-Mode $kind }
        Sync-OutputName $true
        Update-Info
    } finally { $script:selectionLock = $false }
}

function Set-Busy([bool]$busy) {
    $script:busy       = $busy
    $btnGo.Enabled     = -not $busy
    $btnCancel.Enabled = $busy
    foreach ($c in @($txtIn, $txtOut, $btnIn, $btnOut, $txtMB, $btnMinus, $btnPlus, $cmbUnit, $cmbFmt,
                     $chkScale, $txtMax, $chkStrip, $rbVideo, $rbImage)) { $c.Enabled = -not $busy }
    $cmbImageEngine.Enabled = (-not $busy -and $script:mode -eq 'image' -and $script:ImageEngines.Count -gt 1)
    if ($script:ImageEngines.Count -eq 0) { $rbImage.Enabled = $false }
    if ($busy) { $chkCpu.Enabled = $false } else { Update-EncoderUi }
}

function Update-Info {
    if ($script:batchFiles.Count -gt 1) {
        $lblInfo.Text = "$($script:batchFiles.Count) files selected | target applies to each file"
        return
    }
    $path = $txtIn.Text.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $lblInfo.Text = $script:InfoDefault
        return
    }
    $kind = Get-MediaKind $path
    if (-not $kind) { $lblInfo.Text = 'Unsupported file type'; return }
    if ($kind -ne $script:mode) { $lblInfo.Text = "This is a $kind file - switch Mode to $kind"; return }
    $bytes = Get-TargetBytes
    if ($script:mode -eq 'image') { Update-ImageInfo $path $bytes } else { Update-VideoInfo $path $bytes }
}

# =====================================================================
# 7. VIDEO MODE (ffmpeg only)
# =====================================================================
# ---- GPU detection (runs once, after the window opens) ----
# "Listed in ffmpeg" does not mean the hardware exists, so each candidate gets a tiny real test encode.
function Test-Encoder($e) {
    $listed = & $script:ffmpeg -hide_banner -encoders 2>$null | Select-String -SimpleMatch $e.Id
    if (-not $listed) { return $false }
    $testArgs = @('-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=black:s=256x256:d=0.2', '-c:v', $e.Id) +
                ($e.Opts -split ' ') +
                @('-b:v', '1000k', '-pix_fmt', 'yuv420p', '-f', 'null', '-')
    & $script:ffmpeg @testArgs 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-BestEncoder {
    foreach ($e in $script:Encoders) { if (Test-Encoder $e) { return $e } }
    return $script:CpuEncoder
}

# ---- encoder choice ----
# CPU encoders (x264, VP9) run 2 passes with a 5% margin. GPU encoders run 1 pass with an 8% margin.
function Set-Encoder($e) {
    $script:enc         = $e
    $script:totalPasses = if ($e.Gpu) { 1 } else { 2 }
    $script:margin      = if ($e.Gpu) { $script:Cfg.MarginGpu } else { $script:Cfg.MarginCpu }
}

function Get-ChosenEncoder {
    if ((Get-Format).Kind -eq 'vp9') { return $script:Vp9Encoder }   # WebM = VP9, CPU only
    if ($chkCpu.Checked) { return $script:CpuEncoder }
    return $script:detected
}

# Refresh the encoder label and the Force CPU checkbox (not while an encode is running).
function Update-EncoderUi {
    if ($script:mode -ne 'video') { $chkCpu.Enabled = $false; return }
    $lblEnc.Text = 'Encoder: ' + (Get-ChosenEncoder).Name
    if (-not $script:busy) {
        $chkCpu.Enabled = ((Get-Format).Kind -ne 'vp9') -and [bool]$script:detected.Gpu
    }
}

# ---- measuring + info line ----
function Get-Duration([string]$file) {
    # Some containers (mkv/webm) have no format-level duration, so fall back to the video stream.
    foreach ($entry in 'format=duration', 'stream=duration') {
        $out  = & $script:ffprobe -v error -select_streams v:0 -show_entries $entry -of csv=p=0 -i $file 2>$null
        $line = $out | Select-Object -First 1
        $d = 0.0
        if ($line -and [double]::TryParse([string]$line, [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$d) -and $d -gt 0) { return $d }
    }
    return 0.0
}

# Video: split the byte budget into audio + video bitrate (kbps).
function Get-Bitrates([double]$duration, [double]$targetBytes) {
    $totalKbps = ($targetBytes * 8 * $script:margin) / $duration / 1000
    $audio = if ($totalKbps -gt 400) { 128 } else { 64 }
    $video = [math]::Floor($totalKbps - $audio)
    return [pscustomobject]@{ Video = $video; Audio = $audio }
}

function Update-VideoInfo([string]$path, [long]$bytes) {
    if ($script:durPath -ne $path) { $script:durVal = Get-Duration $path; $script:durPath = $path }   # cached: runs on every keystroke
    $d = $script:durVal
    if ($d -le 0) { $lblInfo.Text = $script:InfoDefault; return }
    Set-Encoder (Get-ChosenEncoder)
    if ($bytes -le 0) { $lblInfo.Text = ("Duration: {0:N1}s   |   Enter a target size" -f $d); return }
    $br = Get-Bitrates $d $bytes
    $hint = ''
    if ($br.Video -lt $script:Cfg.MinVideoKbps)       { $hint = '  (target too small)' }
    elseif ($br.Video -lt $script:Cfg.LowQualityKbps) { $hint = '  (very low quality)' }
    $lblInfo.Text = ("Duration: {0:N1}s   |   Est. video bitrate: {1} kbps{2}" -f $d, $br.Video, $hint)
}

# ---- ffmpeg run: arguments, start, progress, step ----
function New-EncodeArguments([int]$pass) {
    $v   = $script:vkbps
    $fmt = $script:fmt

    # Downscale to at most 720p and keep even dimensions for yuv420p.
    if ($script:scale) { $vf = '-vf "scale=-2:''max(2,trunc(min(720,ih)/2)*2)''"' }
    else               { $vf = '-vf "scale=trunc(iw/2)*2:trunc(ih/2)*2"' }

    $acodec = if ($fmt.Kind -eq 'vp9') { 'libopus' } else { 'aac' }
    $base   = "-y -hide_banner -nostats -loglevel error -progress `"$($script:progFile)`" -i `"$($script:inFile)`" $vf -pix_fmt yuv420p"
    $out    = "-c:a $acodec -b:a $($script:akbps)k $($fmt.Flags) -f $($fmt.Muxer) `"$($script:outTmp)`""
    $opts   = $script:enc.Opts

    if (-not $script:enc.Gpu) {
        # CPU: two-pass (x264 or VP9)
        $c = "-c:v $($script:enc.Id) $opts -b:v ${v}k -pass $pass -passlogfile `"$($script:logBase)`""
        if ($pass -eq 1) { return "$base $c -an -f null NUL" }
        return "$base $c $out"
    }
    $c = "-c:v $($script:enc.Id) $opts -b:v ${v}k -maxrate ${v}k -bufsize $($v * 2)k"
    return "$base $c $out"
}

function Start-Pass([int]$pass) {
    $script:pass = $pass
    Set-Content -LiteralPath $script:progFile -Value '' -Encoding ascii -ErrorAction Stop
    Write-Log "Encoding with $($script:enc.Name) - pass $pass/$($script:totalPasses)"
    Start-ToolProcess $script:ffmpeg (New-EncodeArguments $pass)
}

# Reads only the tail of the progress file (it grows for the whole encode).
function Get-ProgressSeconds {
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($script:progFile, 'Open', 'Read', 'ReadWrite')
        $take = [int][math]::Min($fs.Length, 4096)
        if ($take -le 0) { return 0.0 }
        [void]$fs.Seek(-$take, 'End')
        $buf  = New-Object byte[] $take
        $read = $fs.Read($buf, 0, $take)
        $text = [System.Text.Encoding]::ASCII.GetString($buf, 0, $read)
        $m = [regex]::Matches($text, 'out_time_us=(\d+)')
        if ($m.Count -gt 0) { return [double]$m[$m.Count - 1].Groups[1].Value / 1e6 }
    } catch {
    } finally {
        if ($fs) { $fs.Close() }
    }
    return 0.0
}

function Start-VideoRun {
    $script:scale    = $chkScale.Checked
    $script:duration = Get-Duration $script:inFile
    if ($script:duration -le 0) { if ($script:batchActive) { throw 'Could not read the video duration.' }; [void](Show-Msg 'Could not read the video duration. Is the file a valid video?' 'Error' 'OK' 'Warning'); return }

    Set-Encoder (Get-ChosenEncoder)
    $br = Get-Bitrates $script:duration $script:targetBytes
    if ($br.Video -lt $script:Cfg.MinVideoKbps) {
        if ($script:batchActive) { throw 'Target is too small for this video.' }
        [void](Show-Msg "Target is too small for a $([int]$script:duration)s video. Increase the size." 'Error' 'OK' 'Warning'); return }
    if ($br.Video -lt $script:Cfg.LowQualityKbps) {
        $msg = "At $(Format-Bytes $script:targetBytes) the video quality will be very low ($($br.Video) kbps). Continue?"
        if ($script:batchActive) { Write-Log $msg } elseif ((Show-Msg $msg 'Low quality warning' 'YesNo' 'Warning') -ne 'Yes') { return }
    }
    $script:vkbps = $br.Video; $script:akbps = $br.Audio

    Initialize-RunPaths
    if (-not $script:batchActive) { $log.Clear() }; Set-RunProgress 0
    Write-Log ("Video {0} | target {1} | video {2} kbps | audio {3} kbps" -f $script:fmt.Ext, (Format-Bytes $script:targetBytes), $script:vkbps, $script:akbps)
    Set-Busy $true
    $timer.Interval = $script:Cfg.TimerMs
    Start-Pass 1
    $timer.Start()
}

function Step-VideoRun {
    $secs = Get-ProgressSeconds
    $pct  = if ($script:duration -gt 0) { [math]::Min(1.0, $secs / $script:duration) } else { 0 }
    Set-RunProgress ([int]((($script:pass - 1) + $pct) / $script:totalPasses * 100))

    if (-not $script:proc.HasExited) { return }
    $script:proc.WaitForExit()
    $code = $script:proc.ExitCode

    if ($code -ne 0) {
        if ($script:enc.Gpu) {
            # GPU encode failed (driver / unsupported input) -> automatic CPU fallback
            Write-Log "$($script:enc.Name) failed (exit $code): $(Get-ToolError)"
            Write-Log 'Falling back to CPU (x264).'
            Set-Encoder $script:CpuEncoder
            $br = Get-Bitrates $script:duration $script:targetBytes
            $script:vkbps = $br.Video; $script:akbps = $br.Audio
            $lblEnc.Text = 'Encoder: CPU (x264) [fallback]'
            Start-Pass 1
            return
        }
        $detail = Get-ToolError
        Finish $false "ffmpeg failed on pass $($script:pass) (exit code $code). $detail"
        if ($script:batchActive) { return }
        [void](Show-Msg "Compression failed.`n`n$detail" 'Error' 'OK' 'Error')
        return
    }
    if ($script:pass -lt $script:totalPasses) {
        if (-not (Test-Path -LiteralPath ($script:logBase + '-0.log') -PathType Leaf)) {
            $detail = Get-ToolError
            throw "FFmpeg completed pass 1 without a usable statistics file. $detail"
        }
        Start-Pass ($script:pass + 1)
        return
    }

    # Success: promote the .part file to the final name
    $sizeBytes = (Get-Item -LiteralPath $script:outTmp -ErrorAction Stop).Length
    if ($sizeBytes -le 0) { throw 'FFmpeg produced an empty file.' }
    Publish-Output
    $msg = "Done: $($script:outFile)`n$(Format-Bytes $sizeBytes) (target $(Format-Bytes $script:targetBytes))"
    if ($sizeBytes -gt $script:targetBytes) { $msg += "`n`nWarning: the file is larger than the target. Try a smaller target size." }
    Finish $true ($msg -replace "`n", ' ')
    if ($script:batchActive) { return }
    $r = Show-Msg ($msg + "`n`nOpen the output folder?") 'Done' 'YesNo' 'Information'
    if ($r -eq 'Yes') { Start-Process explorer.exe -ArgumentList "/select,`"$($script:outFile)`"" }
}

# =====================================================================
# 8. IMAGE MODE (shared helpers, ImageMagick and CaesiumCLT)
# =====================================================================
# ---- 8A. Shared image information and output ----
# Read WebP dimensions directly from the RIFF header. This avoids depending
# on ImageMagick or FFprobe when CaesiumCLT is selected.
function Get-WebPDimensions([string]$file) {
    $fs = $null
    try {
        $fs = [IO.File]::OpenRead($file)
        $h = New-Object byte[] 30
        $read = $fs.Read($h, 0, $h.Length)
        if ($read -lt 25) { return '' }
        $ascii = [Text.Encoding]::ASCII
        if ($ascii.GetString($h, 0, 4) -ne 'RIFF' -or $ascii.GetString($h, 8, 4) -ne 'WEBP') { return '' }
        switch ($ascii.GetString($h, 12, 4)) {
            'VP8X' {
                if ($read -lt 30) { return '' }
                $w = 1 + [int]$h[24] + ([int]$h[25] -shl 8) + ([int]$h[26] -shl 16)
                $v = 1 + [int]$h[27] + ([int]$h[28] -shl 8) + ([int]$h[29] -shl 16)
            }
            'VP8L' {
                if ($h[20] -ne 47) { return '' }
                $w = 1 + ([int]$h[21] -bor (([int]$h[22] -band 63) -shl 8))
                $v = 1 + (([int]$h[22] -shr 6) -bor ([int]$h[23] -shl 2) -bor (([int]$h[24] -band 15) -shl 10))
            }
            'VP8 ' {
                if ($read -lt 30 -or $h[23] -ne 157 -or $h[24] -ne 1 -or $h[25] -ne 42) { return '' }
                $w = [BitConverter]::ToUInt16($h, 26) -band 16383
                $v = [BitConverter]::ToUInt16($h, 28) -band 16383
            }
            default { return '' }
        }
        if ($w -gt 0 -and $v -gt 0) { return "${w}x${v}" }
    } catch {} finally { if ($fs) { $fs.Dispose() } }
    return ''
}

function Get-CaesiumDimensions([string]$file) {
    if ([IO.Path]::GetExtension($file) -ieq '.webp') { return (Get-WebPDimensions $file) }
    $im = $null
    try {
        $im = [Drawing.Image]::FromFile($file)
        return ('{0}x{1}' -f $im.Width, $im.Height)
    } catch {} finally { if ($im) { $im.Dispose() } }
    return ''
}

# Image dimensions in WIDTHxHEIGHT format, using the selected engine's information path.
function Get-Dimensions([string]$file) {
    if ((Get-ImageEngine) -eq 'CaesiumCLT') { return (Get-CaesiumDimensions $file) }
    if (-not $script:magick) { return '' }
    $coder = $script:ImageExts[[IO.Path]::GetExtension($file).ToLowerInvariant()]
    if (-not $coder) { return '' }
    try {
        $out  = & $script:magick identify -limit time 30 -format '%wx%h' "${coder}:${file}[0]" 2>$null
        $line = [string]($out | Select-Object -First 1)
        if ($line -match '^\d+x\d+$') { return $line }
    } catch {}
    return ''
}

function Update-ImageInfo([string]$path, [long]$bytes) {
    if (-not (Test-ImageEngineInput $path)) {
        $lblInfo.Text = 'CaesiumCLT supports JPG, PNG and WebP. Use ImageMagick for BMP or TIFF.'
        return
    }
    if ($script:dimPath -ne $path) { $script:dimVal = Get-Dimensions $path; $script:dimPath = $path }
    $orig = (Get-Item -LiteralPath $path).Length
    if ($orig -le 0) { $lblInfo.Text = 'The input file is empty.'; return }
    $dims = if ($script:dimVal) { " ($($script:dimVal))" } else { '' }
    $text = "Original: $(Format-Bytes $orig)$dims"
    if ($bytes -le 0)           { $text += '   |   Enter a target size' }
    elseif ($bytes -ge $orig)   { $text += '   |   Target is not smaller than the original' }
    else                        { $text += ("   |   Needs {0:N0}% of the original size" -f ($bytes / $orig * 100)) }
    $lblInfo.Text = $text
}

function Complete-ImageRun([string]$how) {
    # Both engines must pass the same final size check before publishing.
    $actual = (Get-Item -LiteralPath $script:imgBest -ErrorAction Stop).Length
    if ($actual -le 0 -or $actual -gt $script:targetBytes) { throw 'The final image does not meet the target size.' }
    # Stage next to the final output so publication is a same-volume operation.
    Copy-Item -LiteralPath $script:imgBest -Destination $script:outTmp -ErrorAction Stop
    Publish-Output
    $msg = "Done: $($script:outFile)`n$(Format-Bytes $actual) (target $(Format-Bytes $script:targetBytes))`n$($script:imageEngine): $how"
    Finish $true ($msg -replace "`n", ' | ')
    if ($script:batchActive) { return }
    $r = Show-Msg ($msg + "`n`nOpen the output folder?") 'Done' 'YesNo' 'Information'
    if ($r -eq 'Yes') { Start-Process explorer.exe -ArgumentList "/select,`"$($script:outFile)`"" }
}

# Shared adaptive resolution search. Estimate from the size ratio, then
# refine the bracket between fitting and oversized resolutions.
function Get-NextImageScale([long]$size) {
    $s = $script:img
    $minScale = $script:Cfg.ImgScaleMin
    if ($s.ScaleLow -gt 0) {
        if (($s.ScaleHigh - $s.ScaleLow) -le 1) { return 0 }
        return [int][math]::Floor(($s.ScaleLow + $s.ScaleHigh) / 2.0)
    }
    if ($s.Scale -le $minScale) { return 0 }
    $ratio = $script:targetBytes / [double]$size
    $estimate = [int][math]::Floor($s.Scale * [math]::Sqrt($ratio) * $script:Cfg.ImgScaleMargin)
    return [int][math]::Max($minScale, [math]::Min($s.Scale - 1, $estimate))
}

# ---- 8B. ImageMagick: arguments, adaptive quality search, start, step ----
# One ImageMagick call. Input is the private copy in the work folder, read with an explicit coder
# (JPEG:, PNG: ...) so ImageMagick never guesses the format from the file contents.
function New-MagickArguments([int]$scalePct, [int]$quality) {
    $s   = $script:img
    $inp = "$($s.InCoder):$($script:imgSrc)[0]"     # [0] = first frame only
    $out = "$($s.Coder):$($script:imgTry)"
    $a = "-limit memory 2GiB -limit map 4GiB -limit disk 8GiB -limit time 300 `"$inp`" -auto-orient"
    # Convert incompatible color spaces before removing profiles or resizing.
    if ($s.ConvertToSRGB) {
        if ($s.HasICC) { $a += " -profile `"$($s.SRGBProfile)`"" }
        else          { $a += ' -colorspace sRGB' }
    }
    # Keep ICC color information while removing personal metadata.
    if ($script:strip) { $a += ' +profile "!icc,icm" +set comment +set label' }
    if ($script:maxPx -gt 0) { $a += " -resize `"$($script:maxPx)x$($script:maxPx)>`"" }   # '>' = only ever shrink
    if ($scalePct -lt 100)   { $a += " -resize $scalePct%" }
    switch ($s.Kind) {
        'jpg'  { $a += " -background white -alpha remove -alpha off -interlace Plane -sampling-factor 4:2:0 -define jpeg:optimize-coding=on -quality $quality" }
        'webp' { $a += " -define webp:method=5 -quality $quality" }
        'png'  {
            $a += " -define png:compression-level=9 -define png:compression-filter=$($s.PngFilter)"
            if ($script:strip) { $a += ' -define png:exclude-chunk=eXIf,tEXt,zTXt,iTXt,tIME' }
        }
    }
    return "$a `"$out`""
}

function Start-ImageAttempt([int]$scalePct, [int]$quality, [int]$pngFilter = 5) {
    $s = $script:img
    $s.Scale = $scalePct
    $s.Q     = $quality
    $s.PngFilter = $pngFilter
    if ($pngFilter -eq 5) { $s.PngFirstSize = [long]0 }
    $s.Tries++
    Remove-Quiet $script:imgTry
    $qText = if ($s.Kind -eq 'png') { ", PNG filter $pngFilter" } else { ", quality $quality" }
    Write-Log ("Try {0}: scale {1}%{2}" -f $s.Tries, $scalePct, $qText)
    Start-ToolProcess $script:magick (New-MagickArguments $scalePct $quality)
}

# ---- Adaptive quality estimation ----
# Interpolate between a fitting and oversized quality result. Keep the
# estimate away from the ends of the bracket to guarantee search progress.
function Get-NextImageQuality {
    $s = $script:img
    $lo = $s.Lo; $hi = $s.Hi
    if (($hi - $lo) -le 1) { return 0 }
    $mid = [int][math]::Floor(($lo + $hi) / 2.0)
    if ($s.HiSize -le $s.LoSize) { return $mid }
    $fraction = ($script:targetBytes - $s.LoSize) / [double]($s.HiSize - $s.LoSize)
    $estimate = [int][math]::Round($lo + ($hi - $lo) * $fraction)
    $guard = [int][math]::Max(1, [math]::Floor(($hi - $lo) * 0.20))
    $lower = $lo + $guard; $upper = $hi - $guard
    if ($lower -gt $upper) { return $mid }
    return [int][math]::Max($lower, [math]::Min($upper, $estimate))
}

# Start quality refinement at the largest resolution found to fit.
function Start-ImageQualitySearch {
    $s = $script:img
    $s.Phase = 'search'
    $s.Lo = $script:Cfg.ImgQualityMin
    $s.LoSize = $s.BestSize
    if ($s.BestScale -eq 100) {
        $s.Hi = $script:Cfg.ImgQualityMax
        $s.HiSize = $s.TopSize
    } else {
        $s.Hi = $script:Cfg.ImgQualityMax + 1
        $s.HiSize = [long]0
        Start-ImageAttempt $s.BestScale $script:Cfg.ImgQualityMax
        return 'continue'
    }
    $q = Get-NextImageQuality
    if ($q -eq 0) { return 'done' }
    Start-ImageAttempt $s.BestScale $q
    return 'continue'
}

# ---- Adaptive image search ----
# Prioritize resolution, then quality. PNG tries two lossless filters before
# resizing. Always retain a measured output no larger than the target.
function Step-ImageSearch([long]$size) {
    $s  = $script:img
    $ok = ($size -le $script:targetBytes)
    if ($ok -and ($s.BestSize -eq 0 -or $s.Scale -gt $s.BestScale -or
        ($s.Scale -eq $s.BestScale -and $s.Q -gt $s.BestQ))) {
        Copy-Item -LiteralPath $script:imgTry -Destination $script:imgBest -Force -ErrorAction Stop
        $s.BestSize = $size; $s.BestQ = $s.Q; $s.BestScale = $s.Scale
    }
    $qMax   = $script:Cfg.ImgQualityMax
    $qMin   = $script:Cfg.ImgQualityMin

    if ($s.Kind -eq 'png') {
        if (-not $ok -and $s.PngFilter -eq 5) {
            $s.PngFirstSize = $size
            Start-ImageAttempt $s.Scale 0 9
            return 'continue'
        }
        if ($ok) {
            $s.ScaleLow = $s.Scale
            if ($s.Scale -eq 100) { return 'done' }
        } else {
            $s.ScaleHigh = $s.Scale
            if ($s.PngFirstSize -gt 0) { $size = [math]::Min($size, $s.PngFirstSize) }
        }
        $nextScale = Get-NextImageScale $size
        if ($nextScale -eq 0) {
            if ($s.BestSize -gt 0) { return 'done' }
            return 'fail'
        }
        Start-ImageAttempt $nextScale 0 5
        return 'continue'
    }

    switch ($s.Phase) {
        'top' {
            if ($ok) { return 'done' }
            $s.TopSize = $size
            $s.Phase = 'floor'
            Start-ImageAttempt 100 $qMin
            return 'continue'
        }
        'floor' {
            if ($ok) { $s.ScaleLow = 100; return (Start-ImageQualitySearch) }
            $s.ScaleHigh = 100
            $s.Phase = 'scale'
        }
        'search' {
            if ($ok) {
                $s.Lo = $s.Q; $s.LoSize = $size
                if ($s.Q -eq $qMax) { return 'done' }
            } else {
                $s.Hi = $s.Q; $s.HiSize = $size
            }
            $nextQuality = Get-NextImageQuality
            if ($nextQuality -eq 0) { return 'done' }
            Start-ImageAttempt $s.BestScale $nextQuality
            return 'continue'
        }
        'scale' {
            if ($ok) { $s.ScaleLow = $s.Scale }
            else     { $s.ScaleHigh = $s.Scale }
        }
    }
    $nextScale = Get-NextImageScale $size
    if ($nextScale -eq 0) {
        if ($s.BestSize -le 0) { return 'fail' }
        return (Start-ImageQualitySearch)
    }
    Start-ImageAttempt $nextScale $qMin
    return 'continue'
}

function Start-MagickRun {
    $fmt   = $script:fmt
    $inExt = [IO.Path]::GetExtension($script:inFile).ToLowerInvariant()

    $m = 0
    $script:maxPx = 0
    if ([int]::TryParse($txtMax.Text.Trim(), [ref]$m) -and $m -gt 0) { $script:maxPx = $m }
    $script:strip = $chkStrip.Checked

    $script:imgSrc  = Join-Path $script:workDir ('src'  + $inExt)
    $script:imgTry  = Join-Path $script:workDir ('try'  + $fmt.Ext)
    $script:imgBest = Join-Path $script:workDir ('best' + $fmt.Ext)
    Copy-Item -LiteralPath $script:inFile -Destination $script:imgSrc -Force -ErrorAction Stop

    # ---- Source color management ----
    $inCoder = $script:ImageExts[$inExt]
    $colorInfo = & $script:magick identify -quiet -limit time 30 -format '%[colorspace]|%[profiles]' "${inCoder}:$($script:imgSrc)[0]" 2>$null
    if (-not $colorInfo) { throw 'Could not determine the source image color space.' }
    $colorParts = ([string]($colorInfo | Select-Object -First 1)) -split '\|', 2
    $colorSpace = $colorParts[0]
    $hasICC = ($colorParts.Count -gt 1 -and $colorParts[1] -match '\b(icc|icm)\b')
    $srgbProfile = Join-Path (Split-Path $script:magick -Parent) 'sRGB.icc'
    $convertToSRGB = ($colorSpace -eq 'CMYK' -or ($fmt.Kind -eq 'webp' -and $colorSpace -match 'Gray'))
    if ($convertToSRGB -and $hasICC -and -not (Test-Path -LiteralPath $srgbProfile -PathType Leaf)) {
        throw 'The bundled sRGB.icc color profile is missing.'
    }

    $script:img = @{
        # Format and color management.
        Kind = $fmt.Kind; Coder = $fmt.Coder; InCoder = $inCoder
        HasICC = [bool]$hasICC; ConvertToSRGB = $convertToSRGB; SRGBProfile = $srgbProfile
        # Adaptive search state.
        Phase = 'top'; Lo = 0; Hi = 0; Q = 0; Scale = 100; Tries = 0
        ScaleLow = 0; ScaleHigh = 101; LoSize = [long]0; HiSize = [long]0; TopSize = [long]0
        PngFilter = 5; PngFirstSize = [long]0
        # Best valid result.
        BestSize = [long]0; BestQ = 0; BestScale = 100
    }
    if (-not $script:batchActive) { $log.Clear() }; Set-RunProgress 0
    $extra = if ($script:maxPx -gt 0) { " | max $($script:maxPx) px" } else { '' }
    Write-Log ("ImageMagick {0} | target {1}{2}" -f $fmt.Ext, (Format-Bytes $script:targetBytes), $extra)
    if ($hasICC) { Write-Log 'ICC color profile detected.' }
    if ($convertToSRGB) { Write-Log 'Converting incompatible color space to sRGB.' }
    if ($script:strip) { Write-Log 'Metadata removal enabled; compatible ICC profile preserved.' }
    Set-Busy $true
    $timer.Interval = $script:Cfg.ImageTimerMs
    $q = if ($fmt.Kind -eq 'png') { 0 } else { $script:Cfg.ImgQualityMax }
    Start-ImageAttempt 100 $q
    $timer.Start()
}

function Step-MagickRun {
    $s = $script:img
    Set-RunProgress ([int][math]::Min(95, 8 * $s.Tries))
    if (-not $script:proc.HasExited) { return }
    $script:proc.WaitForExit()
    $code = $script:proc.ExitCode

    if ($code -ne 0) {
        $detail = Get-ToolError
        Finish $false "ImageMagick failed (exit code $code). $detail"
        if ($script:batchActive) { return }
        [void](Show-Msg "Image compression failed.`n`n$detail" 'Error' 'OK' 'Error')
        return
    }

    $size = (Get-Item -LiteralPath $script:imgTry -ErrorAction Stop).Length
    if ($size -le 0) { throw 'ImageMagick produced an empty file.' }
    Write-Log ("   -> {0}" -f (Format-Bytes $size))
    $next = Step-ImageSearch $size
    if ($next -eq 'continue') { return }

    if ($next -eq 'fail') {
        $msg = "Could not reach $(Format-Bytes $script:targetBytes), even at $($script:Cfg.ImgScaleMin)% resolution scale."
        if ($s.Kind -eq 'png') { $msg += " PNG is lossless, so try JPG or WebP." } else { $msg += " Choose a larger target." }
        Finish $false $msg
        if ($script:batchActive) { return }
        [void](Show-Msg $msg 'Target too small' 'OK' 'Warning')
        return
    }

    $how = if ($s.Kind -eq 'png') { "scale $($s.BestScale)%" } else { "quality $($s.BestQ), scale $($s.BestScale)%" }
    Complete-ImageRun $how
}

# ---- 8C. CaesiumCLT: native target-size compression ----
# Caesium handles JPEG/WebP quality search internally. PNG uses lossless
# optimization. Measure real output and refine resolution when necessary.
# Never use another compression engine as a hidden fallback.
function New-CaesiumArguments([int]$scalePct) {
    $s = $script:img
    if ($s.Kind -eq 'png') {
        $a = "--lossless --png-opt-level $($script:Cfg.CaesiumPngOpt)"
    } else {
        $a = "--max-size $($script:targetBytes)"
    }
    # Explicit conversion to the same format is rejected by CaesiumCLT.
    if ($s.ConvertFormat) { $a += " --format $($s.ConvertFormat)" }
    if ($script:strip) { $a += ' --keep-orientation' }
    else               { $a += ' --exif' }
    # JPEG ICC profiles are retained by default (do not use --strip-icc).
    if ($s.BaseEdge -gt 0) {
        $edge = [int][math]::Max(1, [math]::Floor($s.BaseEdge * $scalePct / 100.0))
        if ($scalePct -lt 100 -or $script:maxPx -gt 0) { $a += " --long-edge $edge --no-upscale" }
    } elseif ($script:maxPx -gt 0) {
        $a += " --long-edge $($script:maxPx) --no-upscale"
    }
    return "$a --overwrite all --json -o `"$($s.OutputDir)`" `"$($script:imgSrc)`""
}

function Start-CaesiumAttempt([int]$scalePct) {
    $s = $script:img
    $s.Scale = $scalePct; $s.Tries++
    Remove-Quiet $script:imgTry
    Remove-Quiet $s.JsonFile
    $method = if ($s.Kind -eq 'png') { 'lossless PNG' } else { 'native target size' }
    Write-Log ("Try {0}: scale {1}% | {2}" -f $s.Tries, $scalePct, $method)
    Start-ToolProcess $script:caesium (New-CaesiumArguments $scalePct) $s.JsonFile
}

function Start-CaesiumRun {
    $fmt = $script:fmt
    $inExt = [IO.Path]::GetExtension($script:inFile).ToLowerInvariant()
    if ($inExt -eq '.jpeg') { $inExt = '.jpg' }
    $m = 0; $script:maxPx = 0
    if ([int]::TryParse($txtMax.Text.Trim(), [ref]$m) -and $m -gt 0) { $script:maxPx = $m }
    $script:strip = $chkStrip.Checked

    $outDir = Join-Path $script:workDir 'caesium-out'
    New-Item -ItemType Directory -Path $outDir -ErrorAction Stop | Out-Null
    $script:imgSrc = Join-Path $script:workDir ('src' + $inExt)
    $script:imgTry = Join-Path $outDir ('src' + $fmt.Ext)
    $script:imgBest = Join-Path $script:workDir ('best' + $fmt.Ext)
    Copy-Item -LiteralPath $script:inFile -Destination $script:imgSrc -Force -ErrorAction Stop

    $dims = Get-CaesiumDimensions $script:imgSrc
    $baseEdge = 0
    if ($dims -match '^(\d+)x(\d+)$') {
        $baseEdge = [int][math]::Max([int]$Matches[1], [int]$Matches[2])
        if ($script:maxPx -gt 0) { $baseEdge = [math]::Min($baseEdge, $script:maxPx) }
    }
    $convert = ''
    if ($inExt -ne $fmt.Ext) {
        $convert = if ($fmt.Kind -eq 'jpg') { 'jpeg' } else { $fmt.Kind }
    }
    $script:img = @{
        Kind = $fmt.Kind; ConvertFormat = $convert; OutputDir = $outDir
        JsonFile = Join-Path $script:workDir 'caesium-result.json'
        BaseEdge = $baseEdge; Scale = 100; ScaleLow = 0; ScaleHigh = 101; Tries = 0
        BestSize = [long]0; BestScale = 100
    }
    if (-not $script:batchActive) { $log.Clear() }; Set-RunProgress 0
    $extra = if ($script:maxPx -gt 0) { " | max $($script:maxPx) px" } else { '' }
    Write-Log ("CaesiumCLT {0} | target {1}{2}" -f $fmt.Ext, (Format-Bytes $script:targetBytes), $extra)
    if ($script:strip) { Write-Log 'Metadata removal enabled; orientation retained where supported. JPEG ICC retained by default.' }
    if ($baseEdge -eq 0) { Write-Log 'Source dimensions unknown; automatic resolution refinement may be unavailable.' }
    Set-Busy $true
    $timer.Interval = $script:Cfg.ImageTimerMs
    Start-CaesiumAttempt 100
    $timer.Start()
}

function Step-CaesiumRun {
    $s = $script:img
    Set-RunProgress ([int][math]::Min(95, 8 * $s.Tries))
    if (-not $script:proc.HasExited) { return }
    $script:proc.WaitForExit()
    $code = $script:proc.ExitCode
    $result = $null
    try { $result = Get-Content -LiteralPath $s.JsonFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch {}
    $fileResult = @($result.files) | Select-Object -First 1
    # CaesiumCLT may report per-file errors in JSON even if its exit code is 0.
    if ($code -ne 0 -or -not $result -or $result.error -or $fileResult.status -ne 'success' -or
        -not (Test-Path -LiteralPath $script:imgTry -PathType Leaf)) {
        $detail = if ($result.error) { $result.error } elseif ($fileResult.message) { $fileResult.message } else { Get-ToolError }
        if (-not $detail) { $detail = 'No valid output was produced.' }
        Finish $false "CaesiumCLT failed (exit code $code). $detail"
        if ($script:batchActive) { return }
        [void](Show-Msg "CaesiumCLT compression failed.`n`n$detail" 'Error' 'OK' 'Error')
        return
    }

    $size = (Get-Item -LiteralPath $script:imgTry -ErrorAction Stop).Length
    if ($size -le 0) { throw 'CaesiumCLT produced an empty file.' }
    Write-Log ("   -> {0}" -f (Format-Bytes $size))
    if ($size -le $script:targetBytes) {
        if ($s.BestSize -eq 0 -or $s.Scale -gt $s.BestScale) {
            Copy-Item -LiteralPath $script:imgTry -Destination $script:imgBest -Force -ErrorAction Stop
            $s.BestSize = $size; $s.BestScale = $s.Scale
        }
        $s.ScaleLow = $s.Scale
        if ($s.Scale -eq 100) { Complete-ImageRun "scale 100%"; return }
    } else {
        $s.ScaleHigh = $s.Scale
    }

    $nextScale = if ($s.BaseEdge -gt 0) { Get-NextImageScale $size } else { 0 }
    if ($nextScale -gt 0) { Start-CaesiumAttempt $nextScale; return }
    if ($s.BestSize -gt 0) { Complete-ImageRun "scale $($s.BestScale)%"; return }

    $msg = if ($s.BaseEdge -gt 0) {
        "Could not reach $(Format-Bytes $script:targetBytes), even at $($script:Cfg.ImgScaleMin)% resolution scale."
    } else {
        'Could not reach the target and source dimensions could not be read. Try ImageMagick or a larger target.'
    }
    if ($s.Kind -eq 'png') { $msg += ' PNG is lossless; try JPG or WebP.' }
    Finish $false $msg
    if ($script:batchActive) { return }
    [void](Show-Msg $msg 'Target too small' 'OK' 'Warning')
}

# ---- 8D. Image engine dispatch ----
function Start-ImageRun {
    $script:imageEngine = Get-ImageEngine
    Initialize-RunPaths
    switch ($script:imageEngine) {
        'ImageMagick' { Start-MagickRun }
        'CaesiumCLT'  { Start-CaesiumRun }
        default       { throw 'No image compression engine is selected.' }
    }
}

function Step-ImageRun {
    switch ($script:imageEngine) {
        'ImageMagick' { Step-MagickRun }
        'CaesiumCLT'  { Step-CaesiumRun }
        default       { throw 'Unknown image compression engine.' }
    }
}

# =====================================================================
# 9. RUN CONTROL (shared: stop, finish, and the timer that drives both modes)
# =====================================================================
# ---- 9A. Run paths and output publication ----
function Initialize-RunPaths {
    if ($script:workDir -or $script:outTmp) { throw 'A previous compression run has not been cleaned up.' }
    $id = [guid]::NewGuid().ToString('N')
    $dir = Join-Path $env:TEMP ('vc_' + $id)
    $part = Join-Path (Split-Path $script:outFile -Parent) ('vc_' + $id + '.part')
    if ((Test-Path -LiteralPath $dir) -or (Test-Path -LiteralPath $part)) { throw 'Temporary path already exists.' }
    New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null
    $script:workDir = $dir
    $script:outTmp  = $part
    $script:logBase  = Join-Path $dir 'pass'
    $script:progFile = Join-Path $dir 'progress.txt'
    $script:errFile  = Join-Path $dir 'tool_err.txt'
}

# Publish only a verified, complete temporary file. A newly appearing output
# is not overwritten unless the user previously approved replacing that path.
function Publish-Output {
    if (-not (Test-Path -LiteralPath $script:outTmp -PathType Leaf)) { throw 'Missing temporary output.' }
    if ($script:outOverwrite -and (Test-Path -LiteralPath $script:outFile -PathType Leaf)) {
        [IO.File]::Replace($script:outTmp, $script:outFile, [NullString]::Value)
    } else {
        [IO.File]::Move($script:outTmp, $script:outFile)
    }
    $script:outTmp = ''
}

# ---- 9B. External process lifecycle ----
function Start-ToolProcess([string]$exe, [string]$arguments, [string]$stdoutFile = '') {
    if ($script:proc) {
        if (-not $script:proc.HasExited) { throw 'A compression process is already running.' }
        $script:proc.Dispose()
        $script:proc = $null
    }
    $start = @{
        FilePath = $exe; ArgumentList = $arguments
        NoNewWindow = $true; PassThru = $true
        RedirectStandardError = $script:errFile; ErrorAction = 'Stop'
    }
    if ($stdoutFile) { $start.RedirectStandardOutput = $stdoutFile }
    $script:proc = Start-Process @start
    $null = $script:proc.Handle   # keep ExitCode available after the process exits
}

function Stop-Encode {
    if (-not $script:proc) { return $true }
    try {
        if (-not $script:proc.HasExited) {
            try { $script:proc.Kill() } catch {}
            if (-not $script:proc.WaitForExit(5000)) { return $false }
        }
        $script:proc.WaitForExit()
        $script:proc.Dispose()
        $script:proc = $null
        return $true
    } catch { return $false }
}

# Last lines the active tool wrote to stderr.
function Get-ToolError {
    try {
        if (Test-Path -LiteralPath $script:errFile) {
            return ((Get-Content -LiteralPath $script:errFile -Tail 12) -join ' | ')
        }
    } catch {}
    return ''
}

# ---- 9C. Cleanup and UI state ----
function Clear-RunFiles {
    Remove-Quiet $script:outTmp
    Remove-Quiet $script:workDir -Recurse
    $script:outTmp = ''; $script:workDir = ''
    $script:logBase = ''; $script:progFile = ''; $script:errFile = ''
    $script:imgSrc = ''; $script:imgTry = ''; $script:imgBest = ''; $script:img = $null
    $script:outOverwrite = $false
}

function Set-RunProgress([int]$percent) {
    if ($script:batchActive) {
        $percent = [int][math]::Floor((100 * $script:batchIndex + $percent) / $script:batchJobs.Count)
    }
    $bar.Value = [math]::Max(0, [math]::Min(100, $percent))
}

# ---- 9D. Batch queue and execution ----
function Start-Batch {
    $bytes = Get-TargetBytes
    if ($bytes -le 0) { throw 'Enter a valid target size per file.' }
    $fmt = Get-Format
    $folder = $txtOut.Text.Trim().Trim('"')
    if ($folder -and -not (Test-Path -LiteralPath $folder -PathType Container)) { throw 'The output folder does not exist.' }
    $inputs = @($script:batchFiles | ForEach-Object { [IO.Path]::GetFullPath($_) })
    $jobs = @()
    foreach ($path in $inputs) {
        if ((Get-MediaKind $path) -ne $script:mode -or ($script:mode -eq 'image' -and -not (Test-ImageEngineInput $path))) { throw "Unsupported input for selected mode or engine: $path" }
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($item.Length -le 0) { throw "Empty input: $path" }
        $dir = if ($folder) { [IO.Path]::GetFullPath($folder) } else { $item.DirectoryName }
        $stem = [IO.Path]::GetFileNameWithoutExtension($path) + '_compressed'
        $out = Join-Path $dir ($stem + $fmt.Ext)
        $n = 2
        while (($inputs -contains $out) -or ($jobs.Output -contains $out) -or (Test-Path -LiteralPath $out)) {
            $out = Join-Path $dir ($stem + '_' + $n + $fmt.Ext); $n++
        }
        $jobs += [pscustomobject]@{ Input = $path; Output = $out }
    }
    $script:batchJobs = $jobs; $script:batchIndex = 0
    $script:batchSuccess = 0; $script:batchFailed = 0
    $script:batchCancelled = $false; $script:batchActive = $true
    $script:fmt = $fmt; $script:targetBytes = $bytes
    $log.Clear(); $bar.Value = 0
    Set-Busy $true
    $script:batchPending = $true; $timer.Start()
}

function Start-NextBatchFile {
    $script:batchPending = $false
    $job = $script:batchJobs[$script:batchIndex]
    $script:inFile = $job.Input; $script:outFile = $job.Output; $script:outOverwrite = $false
    $lblInfo.Text = "Compressing file $($script:batchIndex + 1) of $($script:batchJobs.Count)"
    Write-Log "$($lblInfo.Text): $($job.Input)"
    try {
        if ($script:mode -eq 'image') { Start-ImageRun } else { Start-VideoRun }
    } catch {
        Write-ErrorLog $_.Exception.ToString()
        Finish $false "Could not start: $($_.Exception.Message)"
    }
}

# Cleanup + log only. Callers show any dialogs afterwards.
function Finish([bool]$ok, [string]$msg) {
    $timer.Stop()
    if (-not (Stop-Encode)) {
        Write-Log 'Could not stop the active process. Waiting for it to exit; try Cancel again.'
        $timer.Start()
        return
    }
    Clear-RunFiles
    if ($script:batchActive) {
        Write-Log $msg
        if (-not $script:batchCancelled) {
            if ($ok) { $script:batchSuccess++ } else { $script:batchFailed++ }
            $script:batchIndex++
        }
        Set-RunProgress 0
        if (-not $script:batchCancelled -and $script:batchIndex -lt $script:batchJobs.Count) {
            $script:batchPending = $true; $timer.Start(); return
        }
        $summary = "Batch finished: $($script:batchSuccess) succeeded, $($script:batchFailed) failed, $($script:batchJobs.Count - $script:batchIndex) unprocessed."
        $script:batchPending = $false; $script:batchActive = $false
        Set-Busy $false; Update-Info; Write-Log $summary
        return
    }
    Set-Busy $false
    Write-Log $msg
    $bar.Value = if ($ok) { 100 } else { 0 }
}

# ---- 9E. Progress timer ----
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $script:Cfg.TimerMs
$timer.Add_Tick({
    try {
        if ($script:batchActive -and $script:batchPending) { Start-NextBatchFile; return }
        if ($script:batchActive -and $script:batchCancelled) { Finish $false 'Cancelled.'; return }
        if (-not $script:busy -or -not $script:proc) { return }
        if ($script:mode -eq 'image') { Step-ImageRun } else { Step-VideoRun }
    } catch {
        Write-ErrorLog $_.Exception.ToString()
        Finish $false "Unexpected error: $($_.Exception.Message)"
        if ($script:batchFiles.Count -gt 1) { return }
        [void](Show-Msg "Unexpected error:`n$($_.Exception.Message)`n`nDetails: $($script:ErrLog)" 'Error' 'OK' 'Error')
    }
})

# =====================================================================
# 10. EVENTS
# =====================================================================
# ---- mode ----
$rbVideo.Add_CheckedChanged({ if (-not $script:modeLock -and $rbVideo.Checked) { Set-Mode 'video' } })
$rbImage.Add_CheckedChanged({ if (-not $script:modeLock -and $rbImage.Checked) { Set-Mode 'image' } })
$cmbImageEngine.Add_SelectedIndexChanged({
    if ($script:modeLock -or $script:busy) { return }
    $script:dimPath = ''; $script:dimVal = ''
    if ($script:mode -eq 'image') { Update-Info }
})

# ---- input / output files ----
$btnIn.Add_Click({
    $vid = ($script:VideoExts | ForEach-Object { "*$_" }) -join ';'
    $exts = if ((Get-ImageEngine) -eq 'CaesiumCLT') { $script:CaesiumExts } else { $script:ImageExts.Keys }
    $img = ($exts | ForEach-Object { "*$_" }) -join ';'
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter      = "Supported files|$vid;$img|Video files|$vid|Image files|$img|All files|*.*"
    $dlg.FilterIndex = if ($script:mode -eq 'image') { 3 } else { 2 }
    $dlg.Multiselect = $true
    try { if ($dlg.ShowDialog() -eq 'OK') { Set-InputFiles $dlg.FileNames } } finally { $dlg.Dispose() }
})
$btnOut.Add_Click({
    if ($script:batchFiles.Count -gt 1) {
        $folderDlg = New-Object System.Windows.Forms.FolderBrowserDialog
        try { if ($folderDlg.ShowDialog() -eq 'OK') { $txtOut.Text = $folderDlg.SelectedPath } } finally { $folderDlg.Dispose() }
        return
    }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    if ($script:mode -eq 'image') { $dlg.Filter = 'JPG image|*.jpg|WebP image|*.webp|PNG image|*.png' }
    else                          { $dlg.Filter = 'MP4 video|*.mp4|MKV video|*.mkv|MOV video|*.mov|WebM video|*.webm' }
    $dlg.FilterIndex = $cmbFmt.SelectedIndex + 1
    if ($dlg.ShowDialog() -eq 'OK') {
        $txtOut.Text = $dlg.FileName
        $cmbFmt.SelectedIndex = $dlg.FilterIndex - 1   # triggers the extension sync below
    }
})
$txtIn.Add_DragEnter({ if ($_.Data.GetDataPresent('FileDrop')) { $_.Effect = 'Copy' } })
$txtIn.Add_DragDrop({ if (-not $script:busy) { Set-InputFiles ($_.Data.GetData('FileDrop')) } })

$txtIn.Add_TextChanged({
    if ($script:selectionLock) { return }
    $script:batchFiles = @()
    $path = $txtIn.Text.Trim().Trim('"')
    $script:durPath = ''; $script:durVal = 0.0
    $script:dimPath = ''; $script:dimVal = ''
    if ([string]::IsNullOrWhiteSpace($path)) { Sync-OutputName $true; Update-Info; return }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $kind = Get-MediaKind $path
        if ($kind -and $kind -ne $script:mode) { Set-Mode $kind }   # a picture in Video mode (or the reverse) switches the mode
        Sync-OutputName $false
    } else { Sync-OutputName $true }
    Update-Info
})

# ---- target size, format and options ----
$txtMB.Add_KeyPress({
    if (-not [char]::IsControl($_.KeyChar) -and -not [char]::IsDigit($_.KeyChar)) { $_.Handled = $true }
})
$txtMB.Add_TextChanged({
    $clean = $txtMB.Text -replace '\D', ''          # also strips pasted non-digits
    if ($clean -ne $txtMB.Text) { $txtMB.Text = $clean; $txtMB.SelectionStart = $txtMB.Text.Length }
    Update-Info
})
$btnMinus.Add_Click({
    $step = Get-SizeStep
    $n = [long]0; [void][long]::TryParse($txtMB.Text.Trim(), [ref]$n)
    if ($n -gt $step) { $txtMB.Text = [string]($n - $step) } elseif ($n -gt 1) { $txtMB.Text = '1' }
})
$btnPlus.Add_Click({
    $step = Get-SizeStep
    $n = [long]0; [void][long]::TryParse($txtMB.Text.Trim(), [ref]$n)
    $txtMB.Text = [string]([math]::Min($n + $step, 99999999))
})
$cmbUnit.Add_SelectedIndexChanged({ Update-Info })

$txtMax.Add_KeyPress({
    if (-not [char]::IsControl($_.KeyChar) -and -not [char]::IsDigit($_.KeyChar)) { $_.Handled = $true }
})
$txtMax.Add_TextChanged({
    $clean = $txtMax.Text -replace '\D', ''
    if ($clean -ne $txtMax.Text) { $txtMax.Text = $clean; $txtMax.SelectionStart = $txtMax.Text.Length }
})

$chkCpu.Add_CheckedChanged({ Update-EncoderUi; Update-Info })
$cmbFmt.Add_SelectedIndexChanged({
    if ($script:modeLock) { return }
    # keep the output file extension in sync with the chosen format
    $o = $txtOut.Text.Trim().Trim('"')
    if ($o -and $script:batchFiles.Count -le 1) { $txtOut.Text = [IO.Path]::ChangeExtension($o, (Get-Format).Ext) }
    Update-EncoderUi
    Update-Info
})

# ---- run / cancel ----
$btnCancel.Add_Click({ if ($script:batchActive) { $script:batchCancelled = $true; $script:batchPending = $false }; Finish $false 'Cancelled.' })

$btnGo.Add_Click({
    try {
        if ($script:batchFiles.Count -gt 1) { Start-Batch; return }
        # ---- validate input ----
        $in = $txtIn.Text.Trim().Trim('"')
        if ([string]::IsNullOrWhiteSpace($in) -or -not (Test-Path -LiteralPath $in -PathType Leaf)) { [void](Show-Msg 'Select a valid input file.' 'Error' 'OK' 'Warning'); return }
        $inFull = [IO.Path]::GetFullPath($in)
        $kind = Get-MediaKind $inFull
        if ($kind -ne $script:mode) {
            [void](Show-Msg "This file is not a $($script:mode) file. Switch the Mode, or choose another file." 'Wrong file type' 'OK' 'Warning'); return }
        if ($kind -eq 'image' -and -not (Test-ImageEngineInput $inFull)) {
            [void](Show-Msg 'The selected image engine does not support this input. CaesiumCLT supports JPG, PNG and WebP. Use ImageMagick for BMP or TIFF.' 'Unsupported input' 'OK' 'Warning'); return
        }

        # ---- validate target size (box starts empty) ----
        $bytes = Get-TargetBytes
        if ($bytes -le 0) {
            [void](Show-Msg "Enter a target size, for example 20 MB for a video or 500 KB for an image (maximum $($script:Cfg.MaxMB) MB)." 'Target size needed' 'OK' 'Warning')
            $txtMB.Focus(); return }

        # ---- validate output ----
        $out = $txtOut.Text.Trim().Trim('"')
        if ([string]::IsNullOrWhiteSpace($out)) { [void](Show-Msg 'Choose an output file.' 'Error' 'OK' 'Warning'); return }
        $fmt = Get-Format
        if ([IO.Path]::GetExtension($out) -ine $fmt.Ext) { $out = [IO.Path]::ChangeExtension($out, $fmt.Ext) }
        $txtOut.Text = $out
        $outFull = [IO.Path]::GetFullPath($out)
        if ($outFull -ieq $inFull) { [void](Show-Msg 'Output must be a different file than the input.' 'Error' 'OK' 'Warning'); return }
        if (-not (Test-Path -LiteralPath (Split-Path $outFull -Parent) -PathType Container)) {
            [void](Show-Msg 'The output folder does not exist.' 'Error' 'OK' 'Warning'); return }
        if (Test-Path -LiteralPath $outFull -PathType Container) {
            [void](Show-Msg 'Output must be a file, not a folder.' 'Error' 'OK' 'Warning'); return
        }
        $overwrite = Test-Path -LiteralPath $outFull -PathType Leaf
        if ($overwrite) {
            if ((Show-Msg "$outFull already exists.`n`nOverwrite it?" 'Confirm' 'YesNo' 'Question') -ne 'Yes') { return }
        }

        $origBytes = (Get-Item -LiteralPath $inFull -ErrorAction Stop).Length
        if ($origBytes -le 0) {
            [void](Show-Msg 'The input file is empty.' 'Error' 'OK' 'Warning'); return
        }
        if ($bytes -ge $origBytes) {
            $msg = "Target ({0}) is not smaller than the source ({1}). Continue anyway?" -f (Format-Bytes $bytes), (Format-Bytes $origBytes)
            if ((Show-Msg $msg 'Confirm' 'YesNo' 'Question') -ne 'Yes') { return }
        }

        $script:fmt         = $fmt
        $script:inFile      = $inFull
        $script:outFile     = $outFull
        $script:outOverwrite = $overwrite
        $script:targetBytes = $bytes

        if ($script:mode -eq 'image') { Start-ImageRun } else { Start-VideoRun }
    } catch {
        Write-ErrorLog $_.Exception.ToString()
        Finish $false "Could not start: $($_.Exception.Message)"
        [void](Show-Msg "Could not start:`n$($_.Exception.Message)`n`nDetails: $($script:ErrLog)" 'Error' 'OK' 'Error')
    }
})

# ---- window lifecycle ----
$form.Add_FormClosing({
    param($sender, $eventArgs)
    $timer.Stop()
    if (-not (Stop-Encode)) {
        $eventArgs.Cancel = $true
        $timer.Start()
        [void](Show-Msg 'Could not stop the active process. Try Cancel again before closing.' 'Warning' 'OK' 'Warning')
        return
    }
    Clear-RunFiles
})

# GPU detection runs after the window is visible (it takes a few seconds on some PCs).
$form.Add_Shown({
    if ($script:ImageEngines.Count -eq 0) {
        $rbImage.Enabled = $false
        $rbImage.Text    = 'Image (no engine found)'
    }
    $lblEnc.Text = 'Encoder: detecting GPU...'
    $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    try { $script:detected = Get-BestEncoder } catch { $script:detected = $script:CpuEncoder }
    Set-Encoder (Get-ChosenEncoder)
    Update-EncoderUi
    $btnGo.Enabled = $true
    Write-Log "Detected video encoder: $($script:detected.Name)"
    if ($script:ImageEngines.Count -gt 0) { Write-Log ('Available image engines: ' + ($script:ImageEngines -join ', ')) }
    if ($script:caesiumUnavailable) { Write-Log ('CaesiumCLT unavailable: ' + $script:caesiumUnavailable) }
})

# =====================================================================
# 11. START
# =====================================================================
try {
    [void]$form.ShowDialog()
} catch {
    Show-Fatal "Fatal error: $($_.Exception.Message)"
}
