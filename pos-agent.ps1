using namespace System.Net.WebSockets
using namespace System.Text
using namespace System.Threading
using namespace System.IO
using namespace System.Diagnostics

# ================= CONFIG =================
$WS_URL = "wss://anzs8ocgha.execute-api.eu-west-2.amazonaws.com/dev"
$RESTAURANT_NUMBER = "12"
$DEVICE_ID = "device-001"
$MACHINE_NAME = "POS-01"

# ================= GLOBAL STATE =================
$global:Running = $true
$global:WebSocket = $null
$global:CTS = New-Object System.Threading.CancellationTokenSource

# ================= JSON HELPERS =================

function ConvertTo-JsonSafe {
    param ([Hashtable]$Object)
    return ($Object | ConvertTo-Json -Depth 10 -Compress)
}

function Send-JsonMessage {
    param ([Hashtable]$Object)

    $json = ConvertTo-JsonSafe $Object
    $bytes = [Encoding]::UTF8.GetBytes($json)
    $segment = New-Object System.ArraySegment[byte] -ArgumentList $bytes

    $global:WebSocket.SendAsync(
        $segment,
        [System.Net.WebSockets.WebSocketMessageType]::Text,
        $true,
        $global:CTS.Token
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
            Write-Host "Heartbeat sent at $(Get-Date -Format T)"
        }
        catch {
            Write-Warning "Heartbeat failed: $_"
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
        $tempFile = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), ".ps1")
        [System.IO.File]::WriteAllBytes($tempFile, $bytes)

        Write-Host "Running script $ScriptName ($tempFile)"

        $outFile = "$tempFile.out"
        $errFile = "$tempFile.err"

        $process = Start-Process powershell `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tempFile`"" `
            -RedirectStandardOutput $outFile `
            -RedirectStandardError $errFile `
            -NoNewWindow -PassThru

        if (-not $process.WaitForExit(60000)) {
            throw "Script execution timed out"
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

        Write-Host "Results sent to server"
    }
    catch {
        Write-Error "Script execution error: $_"
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

# ================= MESSAGE RECEIVER =================

function Receive-Messages {
    $buffer = New-Object byte[] 4096

    while ($global:Running -and $global:WebSocket.State -eq 'Open') {
        $segment = New-Object System.ArraySegment[byte] -ArgumentList $buffer
        $result = $global:WebSocket.ReceiveAsync($segment, $global:CTS.Token).Result

        if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
            Write-Host "WebSocket closed by server"
            break
        }

        $message = [Encoding]::UTF8.GetString($buffer, 0, $result.Count)
        Write-Host "Received: $message"

        try {
            $data = $message | ConvertFrom-Json
            if ($data.action -eq "run_script") {
                Start-Job -ScriptBlock {
                    param ($s, $c, $id)
                    Run-ReceivedScript -ScriptName $s -EncodedScript $c -CommandId $id
                } -ArgumentList $data.script_name, $data.script_content, $data.command_id | Out-Null
            }
            else {
                Write-Host "Message action: $($data.action)"
            }
        }
        catch {
            Write-Warning "Failed to parse message: $_"
        }
    }
}

# ================= CLEAN SHUTDOWN =================

$shutdownHandler = {
    Write-Host "Graceful shutdown started"
    $global:Running = $false

    try {
        Send-JsonMessage @{
            action = "disconnect"
            restaurant_number = $RESTAURANT_NUMBER
            device_id = $DEVICE_ID
        }
        $global:WebSocket.CloseAsync(
            [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
            "Client shutdown",
            [System.Threading.CancellationToken]::None
        ).Wait()
    }
    catch {}
    finally {
        exit
    }
}

Register-EngineEvent PowerShell.Exiting -Action $shutdownHandler | Out-Null

# ================= MAIN =================

$uri = "$WS_URL?restaurantnumber=$RESTAURANT_NUMBER&deviceid=$DEVICE_ID&machine=$MACHINE_NAME"
$global:WebSocket = New-Object System.Net.WebSockets.ClientWebSocket
$global:WebSocket.ConnectAsync([Uri]$uri, $global:CTS.Token).Wait()

Write-Host "Connected to WebSocket server"

Send-JsonMessage @{
    action = "register"
    restaurant_number = $RESTAURANT_NUMBER
    device_id = $DEVICE_ID
    machine = $MACHINE_NAME
}

Write-Host "Registration message sent"

Start-Job { Start-Heartbeat } | Out-Null
Receive-Messages
