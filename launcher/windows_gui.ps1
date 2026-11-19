# =============================================================================
# The launcher window (Windows). start_windows.bat opens it when double-clicked.
# It runs "start_windows.bat --gui-worker", shows its output, and talks to it with LAUNCHER_UI lines:
#   worker -> window: LAUNCHER_UI|READY|<url>, LAUNCHER_UI|STOP_FAILED
#   window -> worker: "stop"
# The same file is used in r_launcher_jp/_en and python_launcher_jp/_en (texts from launcher/start_messages.txt).
# =============================================================================
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$root = $env:LAUNCHER_ROOT
if (-not $root) { $root = (Get-Location).Path }
$worker = Join-Path $root 'start_windows.bat'

$script:Msg = @{}
$messagesPath = Join-Path $root 'launcher/start_messages.txt'
if (Test-Path -LiteralPath $messagesPath) {
    foreach ($line in (Get-Content -Encoding UTF8 -LiteralPath $messagesPath)) {
        if ($line -cmatch '^([a-z_]+)=(.*)$') { $script:Msg[$Matches[1]] = $Matches[2] }
    }
}
function T([string]$Key, [string]$Value = '') {
    if ($script:Msg.ContainsKey($Key)) { return $script:Msg[$Key].Replace('{0}', $Value) }
    return "[$Key] $Value"
}

# --- One window per folder (a second double-click brings the first window back) ---
$sha = [System.Security.Cryptography.SHA256]::Create()
$digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant()))
$folderKey = ([BitConverter]::ToString($digest)).Replace('-', '').Substring(0, 16)
$windowTitle = (T 'gui_title') + ' - ' + (Split-Path -Leaf $root)
$mutex = New-Object System.Threading.Mutex($false, "Local\analysis-launcher-$folderKey")
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic
        [Microsoft.VisualBasic.Interaction]::AppActivate($windowTitle)
    } catch { }
    $owner = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true
    $owner.ShowInTaskbar = $false
    $owner.FormBorderStyle = 'None'
    $owner.Opacity = 0
    $owner.StartPosition = 'CenterScreen'
    $owner.Size = New-Object System.Drawing.Size(1, 1)
    $owner.Show()
    [void][System.Windows.Forms.MessageBox]::Show($owner, (T 'gui_already'), (T 'gui_title'))
    $owner.Dispose()
    return
}

$script:Proc = $null
$script:ReadTask = $null
$script:Url = $null
$script:CanStop = $false
$script:Requested = $false
$script:CloseAfterStop = $false
$script:AllowClose = $false

$form = New-Object System.Windows.Forms.Form
$form.Text = $windowTitle
$form.Font = [System.Drawing.SystemFonts]::MessageBoxFont
$form.Size = New-Object System.Drawing.Size(780, 540)
$form.MinimumSize = New-Object System.Drawing.Size(620, 420)
$form.StartPosition = 'CenterScreen'

$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'
$layout.Padding = New-Object System.Windows.Forms.Padding(16)
$layout.ColumnCount = 1
$layout.RowCount = 6
foreach ($i in 0..5) {
    $style = New-Object System.Windows.Forms.RowStyle
    if ($i -eq 4) { $style.SizeType = 'Percent'; $style.Height = 100 } else { $style.SizeType = 'AutoSize' }
    [void]$layout.RowStyles.Add($style)
}
$form.Controls.Add($layout)

$title = New-Object System.Windows.Forms.Label
$title.Text = (T 'gui_title')
$title.AutoSize = $true
$title.Font = New-Object System.Drawing.Font($form.Font.FontFamily, 16, [System.Drawing.FontStyle]::Bold)
$layout.Controls.Add($title, 0, 0)

$folder = New-Object System.Windows.Forms.Label
$folder.Text = (Split-Path -Leaf $root)
$folder.AutoSize = $true
$folder.ForeColor = [System.Drawing.SystemColors]::GrayText
$layout.Controls.Add($folder, 0, 1)

$status = New-Object System.Windows.Forms.Label
$status.AutoSize = $true
$status.MaximumSize = New-Object System.Drawing.Size(720, 0)
$status.Font = New-Object System.Drawing.Font($form.Font.FontFamily, 11)
$status.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 8)
$layout.Controls.Add($status, 0, 2)

$buttons = New-Object System.Windows.Forms.FlowLayoutPanel
$buttons.AutoSize = $true
$buttons.WrapContents = $true
$layout.Controls.Add($buttons, 0, 3)
function New-Button([string]$Key) {
    $button = New-Object System.Windows.Forms.Button
    $button.Text = (T $Key)
    $button.AutoSize = $true
    $button.Padding = New-Object System.Windows.Forms.Padding(8, 2, 8, 2)
    [void]$buttons.Controls.Add($button)
    return $button
}
$startButton = New-Button 'gui_start'
$browserButton = New-Button 'gui_browser'
$copyButton = New-Button 'gui_copy'
$stopButton = New-Button 'gui_stop'

$log = New-Object System.Windows.Forms.TextBox
$log.Multiline = $true
$log.ReadOnly = $true
$log.ScrollBars = 'Vertical'
$log.WordWrap = $true
$log.Dock = 'Fill'
$log.Font = New-Object System.Drawing.Font('Consolas', 9)
$layout.Controls.Add($log, 0, 4)

$help = New-Object System.Windows.Forms.Label
$help.Text = (T 'gui_help')
$help.AutoSize = $true
$help.MaximumSize = New-Object System.Drawing.Size(720, 0)
$help.ForeColor = [System.Drawing.SystemColors]::GrayText
$help.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
$layout.Controls.Add($help, 0, 5)

$form.add_Resize({
    $width = [Math]::Max(200, $form.ClientSize.Width - 40)
    $status.MaximumSize = New-Object System.Drawing.Size($width, 0)
    $help.MaximumSize = New-Object System.Drawing.Size($width, 0)
})

$escape = [string][char]27
function Add-Log([string]$Text) {
    $clean = [regex]::Replace($Text, [regex]::Escape($escape) + '\[[0-9;?]*[A-Za-z]', '')
    $log.AppendText($clean + "`r`n")
    if ($log.TextLength -gt 100000) {
        $log.Text = $log.Text.Substring(30000)
        $log.SelectionStart = $log.TextLength
        $log.ScrollToCaret()
    }
}

function Update-Buttons {
    $running = ($null -ne $script:Proc)
    $startButton.Enabled = -not $running
    $stopButton.Enabled = ($running -and $script:CanStop -and -not $script:Requested)
    $browserButton.Enabled = ($running -and $null -ne $script:Url)
    $copyButton.Enabled = ($running -and $null -ne $script:Url)
}

function Ask-Choice([string]$Title, [string]$Text, [string]$SafeLabel, [string]$ActionLabel) {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.Font = $form.Font
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.StartPosition = 'CenterParent'
    $dialog.AutoSize = $true
    $dialog.AutoSizeMode = 'GrowAndShrink'
    $dialog.Padding = New-Object System.Windows.Forms.Padding(16)
    $panel = New-Object System.Windows.Forms.FlowLayoutPanel
    $panel.FlowDirection = 'TopDown'
    $panel.AutoSize = $true
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.AutoSize = $true
    $label.MaximumSize = New-Object System.Drawing.Size(460, 0)
    $label.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
    [void]$panel.Controls.Add($label)
    $row = New-Object System.Windows.Forms.FlowLayoutPanel
    $row.AutoSize = $true
    $safe = New-Object System.Windows.Forms.Button
    $safe.Text = $SafeLabel
    $safe.AutoSize = $true
    $safe.DialogResult = [System.Windows.Forms.DialogResult]::No
    $action = New-Object System.Windows.Forms.Button
    $action.Text = $ActionLabel
    $action.AutoSize = $true
    $action.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    [void]$row.Controls.Add($safe)
    [void]$row.Controls.Add($action)
    [void]$panel.Controls.Add($row)
    $dialog.Controls.Add($panel)
    $dialog.AcceptButton = $safe
    $dialog.CancelButton = $safe
    $result = $dialog.ShowDialog($form)
    $dialog.Dispose()
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Open-Browser {
    if (-not $script:Url) { return }
    try { Start-Process $script:Url }
    catch {
        Add-Log $_.Exception.Message
        $status.Text = (T 'gui_open_failed')
    }
}

function Copy-Address {
    if (-not $script:Url) { return }
    [System.Windows.Forms.Clipboard]::SetText($script:Url)
    $status.Text = (T 'gui_copied' $script:Url)
}

function Start-Worker {
    if ($null -ne $script:Proc) { return }
    if (-not (Test-Path -LiteralPath $worker)) {
        $status.Text = (T 'gui_no_worker')
        return
    }
    $script:CanStop = $false
    $script:Requested = $false
    $script:CloseAfterStop = $false
    $script:Url = $null
    $log.Clear()
    $status.Text = (T 'gui_preparing')
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $(if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' })
    $info.Arguments = '/d /c ""' + $worker + '" --gui-worker 2>&1"'
    $info.WorkingDirectory = $root
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.CreateNoWindow = $true
    $info.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try { [void]$process.Start() }
    catch {
        Add-Log $_.Exception.Message
        Complete-Worker 1
        return
    }
    $script:Proc = $process
    $script:ReadTask = $process.StandardOutput.ReadLineAsync()
    Update-Buttons
}

function Request-Stop {
    if ($null -eq $script:Proc -or -not $script:CanStop -or $script:Requested) { return }
    $script:Requested = $true
    $status.Text = (T 'gui_stopping')
    Update-Buttons
    try {
        $script:Proc.StandardInput.Write("stop`r`n")
        $script:Proc.StandardInput.Flush()
    } catch {
        $script:Requested = $false
        Update-Buttons
        Add-Log $_.Exception.Message
    }
}

function Complete-Worker([int]$Code) {
    $script:CanStop = $false
    $script:Requested = $false
    $script:Url = $null
    Update-Buttons
    if ($Code -eq 0) { $status.Text = (T 'gui_stopped') }
    else { $status.Text = (T 'gui_failed' ([string]$Code)) }
    if ($Code -eq 0 -and $script:CloseAfterStop) {
        $script:AllowClose = $true
        $form.Close()
    }
}

function Receive-Line([string]$Line) {
    $Line = $Line.TrimEnd()
    if (-not $Line.StartsWith('LAUNCHER_UI|')) {
        Add-Log $Line
        return
    }
    $parts = $Line.Split('|')
    switch ($parts[1]) {
        'READY' {
            if ($parts.Count -ge 3 -and $parts[2] -match '^http://localhost:[0-9]+(/.*)?$') {
                $script:Url = $parts[2]
                $script:CanStop = $true
                $status.Text = (T 'gui_ready' $script:Url)
                Update-Buttons
                Open-Browser
            }
        }
        'STOP_FAILED' {
            $script:Requested = $false
            $script:CloseAfterStop = $false
            $script:CanStop = $true
            $status.Text = (T 'gui_stop_failed')
            Update-Buttons
        }
    }
}

$script:Receiving = $false
function Receive-Output {
    if ($script:Receiving) { return }
    $script:Receiving = $true
    try {
        while ($null -ne $script:ReadTask -and $script:ReadTask.IsCompleted) {
            $line = $null
            try { $line = $script:ReadTask.Result } catch { $line = $null }
            if ($null -eq $line) {
                $script:ReadTask = $null
                break
            }
            if ($null -ne $script:Proc) { $script:ReadTask = $script:Proc.StandardOutput.ReadLineAsync() }
            else { $script:ReadTask = $null }
            Receive-Line $line
        }
        if ($null -ne $script:Proc -and $null -eq $script:ReadTask -and $script:Proc.HasExited) {
            $code = $script:Proc.ExitCode
            $script:Proc.Dispose()
            $script:Proc = $null
            Complete-Worker $code
        }
    } finally {
        $script:Receiving = $false
    }
}

$startButton.add_Click({ try { Start-Worker } catch { Add-Log $_.Exception.Message } })
$browserButton.add_Click({ try { Open-Browser } catch { Add-Log $_.Exception.Message } })
$copyButton.add_Click({ try { Copy-Address } catch { Add-Log $_.Exception.Message } })
$stopButton.add_Click({ try { Request-Stop } catch { Add-Log $_.Exception.Message } })
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 100
$timer.add_Tick({ try { Receive-Output } catch { Add-Log $_.Exception.Message } })
$form.add_Shown({ try { Start-Worker } catch { Add-Log $_.Exception.Message } })
$form.add_FormClosing({
    param($sender, $closingEvent)
    if ($script:AllowClose -or $null -eq $script:Proc) { return }
    if ($closingEvent.CloseReason -eq [System.Windows.Forms.CloseReason]::WindowsShutDown) { return }
    $closingEvent.Cancel = $true
    if ($script:CanStop -and -not $script:Requested) {
        if (Ask-Choice (T 'gui_quit_title') (T 'gui_quit_text') (T 'gui_back_button') (T 'gui_quit_button')) {
            $script:CloseAfterStop = $true
            Request-Stop
        }
    } else {
        [void][System.Windows.Forms.MessageBox]::Show((T 'gui_busy'), (T 'gui_title'))
    }
})

try {
    $startButton.Enabled = $false
    $stopButton.Enabled = $false
    $browserButton.Enabled = $false
    $copyButton.Enabled = $false
    $timer.Start()
    [System.Windows.Forms.Application]::Run($form)
} finally {
    $timer.Stop()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
