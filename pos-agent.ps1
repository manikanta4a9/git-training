using namespace System.Net.WebSockets
using namespace System.Text
using namespace System.Text.Json
using namespace System.Threading
using namespace System.Diagnostics
using namespace System.IO

# ================= CONFIG =================
$WS_URL = "wss://anzs8ocgha.execute-api.eu-west-2.amazonaws.com/dev"
$RESTAURANT_NUMBER = "12"
$DEVICE_ID = "device-001"
$MACHINE_NAME = "POS-01"

# ================= GLOBAL STATE =================
$global:Running = $true
$global:WebSocket = $null
$global:CTS = [CancellationTokenSource]::new()

# ================= HELPERS =================

function Send-JsonMessage {
    param ($Object)

    $json = [JsonSerializer]::Serialize($Object)
    $bytes = [Encoding]::UTF8.GetBytes($json)
    $segment = [ArraySegment[byte]]::new($bytes)

    $WebSocket.SendAsync(
        $segment,
        [WebSocketMessageType]::Text,
        $true,
        $CTS.Token
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
                timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            }
            Write-Host "Heartbeat sent at $(Get-Date -Format T)"
        }
        catch {
            Write-Warning "Heartbeat error: $_"
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
        $tempFile = [Path]::ChangeExtension([Path]::GetTempFileName(), ".ps1")
        [File]::WriteAllBytes($tempFile, $bytes)

        Write-Host "Received script $ScriptName saved as $tempFile"

        $process = Start-Process pwsh `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tempFile`"" `
            -RedirectStandardOutput "$tempFile.out" `
            -RedirectStandardError "$tempFile.err" `
            -NoNewWindow -PassThru

        if (-not $process.WaitForExit(60000)) {
            throw "Execution timeout"
        }

        $stdout = Get-Content "$tempFile.out" -Raw -ErrorAction Ignore
        $stderr = Get-Content "$tempFile.err" -Raw -ErrorAction Ignore

        Send-JsonMessage @{
            action = "save_results"
            restaurant_number = $RESTAURANT_NUMBER
            device_id = $DEVICE_ID
            command_id = $CommandId ?? "unknown"
            script_name = $ScriptName
            result_output = $stdout.Trim()
            stderr = $stderr.Trim()
            returncode = $process.ExitCode
            execution_status = if ($process.ExitCode -eq 0) { "success" } else { "failed" }
            timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        }

        Write-Host "Execution results sent"
    }
    catch {
        Write-Error "Script execution failed: $_"
        Send-JsonMessage @{
            action = "save_results"
            device_id = $DEVICE_ID
            machine = $MACHINE_NAME
            command_id = $CommandId ?? "unknown"
            script_name = $ScriptName
            stderr = "$_"
            timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        }
    }
    finally {
        if ($tempFile) {
            Remove-Item "$tempFile*" -Force -ErrorAction SilentlyContinue
        }
    }
}

# ================= MESSAGE HANDLER =================

function Receive-Messages {
    $buffer = New-Object byte[] 4096

    while ($global:Running -and $WebSocket.State -eq 'Open') {
        $segment = [ArraySegment[byte]]::new($buffer)
        $result = $WebSocket.ReceiveAsync($segment, $CTS.Token).Result

        if ($result.MessageType -eq 'Close') {
            Write-Host "WebSocket connection closed"
            break
        }

        $message = [Encoding]::UTF8.GetString($buffer, 0, $result.Count)
        Write-Host "Message from server: $message"

        try {
            $data = $message | ConvertFrom-Json
            if ($data.action -eq "run_script") {
                Start-ThreadJob {
                    Run-ReceivedScript `
                        -ScriptName $using:data.script_name `
                        -EncodedScript $using:data.script_content `
                        -CommandId $using:data.command_id
                } | Out-Null
            }
            else {
                Write-Host "Received message type: $($data.action)"
            }
        }
        catch {
            Write-Warning "Failed to parse message: $_"
        }
    }
}

# ================= SHUTDOWN =================

$onExit = {
    Write-Host "Shutting down gracefully"
    $global:Running = $false

    try {
        Send-JsonMessage @{
            action = "disconnect"
            restaurant_number = $RESTAURANT_NUMBER
            device_id = $DEVICE_ID
        }
        $WebSocket.CloseAsync(
            [WebSocketCloseStatus]::NormalClosure,
            "Client disconnect",
            [CancellationToken]::None
        ).Wait()
    }
    catch {}
    finally {
        exit
    }
}

Register-EngineEvent PowerShell.Exiting -Action $onExit | Out-Null

# ================= MAIN =================

$uri = "$WS_URL?restaurantnumber=$RESTAURANT_NUMBER&deviceid=$DEVICE_ID&machine=$MACHINE_NAME"
$WebSocket = [ClientWebSocket]::new()
$WebSocket.ConnectAsync([Uri]$uri, $CTS.Token).Wait()

Write-Host "Connected to WebSocket"

Send-JsonMessage @{
    action = "register"
    restaurant_number = $RESTAURANT_NUMBER
    device_id = $DEVICE_ID
    machine = $MACHINE_NAME
}

Write-Host "Registration message sent"

Start-ThreadJob { Start-Heartbeat } | Out-Null
Receive-Messages
