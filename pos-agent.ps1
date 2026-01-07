# ================= CONFIG =================
$WS_URL = "wss://anzs8ocgha.execute-api.eu-west-2.amazonaws.com/dev"
$RESTAURANT_NUMBER = "12"
$DEVICE_ID = "device-001"
$MACHINE_NAME = "POS-01"

# ================= GLOBAL STATE =================
$global:Running = $true
$global:WebSocket = $null

# ================= JSON SEND =================

function Send-JsonMessage {
    param ([Hashtable]$Object)

    $json = $Object | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $segment = New-Object System.ArraySegment[byte] -ArgumentList $bytes

    $global:WebSocket.SendAsync(
        $segment,
        [System.Net.WebSockets.WebSocketMessageType]::Text,
        $true,
        [System.Threading.CancellationToken]::None
    ).Wait()
}

# ================= HEARTBEAT =================

function Start-Heartbeat {
    while ($global:Running) {
        try {
            Send-JsonMessage @{
                action = "heartbeat"
                restaurant_number = $RESTAURANT_NUMBER
                device_id = $DEVICE_ID
                timestamp = [int][double]::Parse((Get-Date -UFormat %s))
            }
        }
        catch {
            break
        }
        Start-Sleep -Seconds 30
    }
}

# ================= SCRIPT EXECUTION =================

function Run-ReceivedScript {
    param (
        [string]$ScriptName,
        [string]$EncodedScript,
        [string]$CommandId
    )

    $tempFile = $null

    try {
        $bytes = [Convert]::FromBase64String($EncodedScript)
        $tempFile = [System.IO.Path]::ChangeExtension(
            [System.IO.Path]::GetTempFileName(),
            ".ps1"
        )
        [System.IO.File]::WriteAllBytes($tempFile, $bytes)

        $outFile = "$tempFile.out"
        $errFile = "$tempFile.err"

        $process = Start-Process powershell.exe `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tempFile`"" `
            -RedirectStandardOutput $outFile `
            -RedirectStandardError $errFile `
            -NoNewWindow `
            -PassThru

        if (-not $process.WaitForExit(60000)) {
            throw "Timeout"
        }

        $stdout = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content $errFile -Raw -ErrorAction SilentlyContinue

        Send-JsonMessage @{
            action = "save_results"
            restaurant_number = $RESTAURANT_NUMBER
            device_id = $DEVICE_ID
            command_id = if ($CommandId) { $CommandId } else { "unknown" }
            script_name = $ScriptName
            result_output = $stdout.Trim()
            stderr = $stderr.Trim()
            returncode = $process.ExitCode
            execution_status = if ($process.ExitCode -eq 0) { "success" } else { "failed" }
            timestamp = [int][double]::Parse((Get-Date -UFormat %s))
        }
    }
    catch {
        Send-JsonMessage @{
            action = "save_results"
            device_id = $DEVICE_ID
            machine = $MACHINE_NAME
            command_id = if ($CommandId) { $CommandId } else { "unknown" }
            script_name = $ScriptName
            stderr = "$_"
            timestamp = [int][double]::Parse((Get-Date -UFormat %s))
        }
    }
    finally {
        if ($tempFile) {
            Remove-Item "$tempFile*" -Force -ErrorAction SilentlyContinue
        }
    }
}

# ================= RECEIVE LOOP =================

function Receive-Messages {
    $buffer = New-Object byte[] 4096

    while ($global:Running -and $global:WebSocket.State -eq 'Open') {
        $segment = New-Object System.ArraySegment[byte] -ArgumentList $buffer
        $result = $global:WebSocket.ReceiveAsync(
            $segment,
            [System.Threading.CancellationToken]::None
        ).Result

        if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
            break
        }

        $message = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)

        try {
            $data = $message | ConvertFrom-Json
            if ($data.action -eq "run_script") {
                Start-Job -ArgumentList $data.script_name, $data.script_content, $data.command_id `
                    -ScriptBlock {
                        param ($s, $c, $id)
                        Run-ReceivedScript -ScriptName $s -EncodedScript $c -CommandId $id
                    } | Out-Null
            }
        }
        catch {}
    }
}

# ================= SHUTDOWN =================

Register-EngineEvent PowerShell.Exiting -Action {
    $global:Running = $false
    try {
        Send-JsonMessage @{
            action = "disconnect"
            restaurant_number = $RESTAURANT_NUMBER
            device_id = $DEVICE_ID
        }
        $global:WebSocket.CloseAsync(
            [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
            "shutdown",
            [System.Threading.CancellationToken]::None
        ).Wait()
    }
    catch {}
} | Out-Null

# ================= MAIN =================

$uri = "$WS_URL?restaurantnumber=$RESTAURANT_NUMBER&deviceid=$DEVICE_ID&machine=$MACHINE_NAME"
$global:WebSocket = New-Object System.Net.WebSockets.ClientWebSocket

# IMPORTANT: single-argument ConnectAsync (PS 5.1 safe)
$connectTask = $global:WebSocket.ConnectAsync([Uri]$uri)
$connectTask.Wait()

Send-JsonMessage @{
    action = "register"
    restaurant_number = $RESTAURANT_NUMBER
    device_id = $DEVICE_ID
    machine = $MACHINE_NAME
}

Start-Job { Start-Heartbeat } | Out-Null
Receive-Messages
