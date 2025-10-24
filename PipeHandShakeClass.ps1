using namespace System.IO.Pipes
using namespace System.Text

# Pipe server that works as the main module for the handshake protocol
# This is where all messages and commands should be sent from.
# Implement like this:
# $pipeServer = [PipeServer]::new("myPipeName")
# $pipeServer.WaitForConnection()
# $pipeServer.CreateMessageReceiver()
# The order matters a lot because the server and client has to have
# an established connection if the message receiver is to work.
# If not the message receiver will throw an error but you won't see it
class PipeServer {
    [System.IO.Pipes.NamedPipeServerStream]$PipeStream
    [string]$PipeName
    [System.Management.Automation.Runspaces.Runspace]$Runspace
    [System.Management.Automation.PowerShell]$PowerShell
    [bool]$IsConnected
    [bool]$IsRunning
    [hashtable]$SharedData

    PipeServer([string]$pipeName) {
        $this.PipeName = $pipeName
        $this.PipeStream = New-Object System.IO.Pipes.NamedPipeServerStream($pipeName, [PipeDirection]::InOut, 1, [PipeTransmissionMode]::Byte, [PipeOptions]::Asynchronous)
        $this.IsConnected = $false
        $this.IsRunning = $false
        $this.SharedData = [hashtable]::Synchronized(@{ message = "" })
    }

    # Establish connection with client, this is a blocking call and will freeze until
    # a connection with a client is made
    [void] WaitForConnection() {
        Write-Host "Waiting for client connection on pipe: $($this.PipeName)"
        $this.PipeStream.WaitForConnection()
        $this.IsConnected = $true
        Write-Host "Client connected to pipe: $($this.PipeName)"
    }

    # This is more of a utility function to clear the message after reading it
    [void] ResetMessage() {
        $this.SharedData["message"] = ""
    }

    # Writes to the pipe, this is a blocking call
    [void] WriteMessage([string]$message) {
        if (-not $this.IsConnected) {
            throw "Pipe is not connected. Cannot send message."
        }
        $bytes = [Encoding]::UTF8.GetBytes($message)
        $this.PipeStream.Write($bytes, 0, $bytes.Length)
        $this.PipeStream.Flush()
    }

    # Reads from the hashtable, not the pipe, this is not a blocking call
    [string] ReadMessage() {
        if (-not $this.IsConnected) {
            throw "Pipe is not connected. Cannot read message."
        }
        return $this.SharedData.message
    }

    # This makes a runspace that continuously reads from the pipe in the background
    # The data the runspace reads from the pipe is stored to the hashtable SharedData
    # in it's value "message"
    # This means the runspace will always hang on "Read" such that messages are always
    # read right away, and it means we don't have to block the main thread to read messages
    [void] CreateMessageReceiver() {
        if ($this.IsRunning) {
            Write-Host "Message receiver is already running"
            return
        }

        $this.Runspace = [runspacefactory]::CreateRunspace()
        $this.Runspace.Open()
        $this.Runspace.SessionStateProxy.SetVariable("sharedData", $this.SharedData)
        $this.Runspace.SessionStateProxy.SetVariable("pipeStream", $this.PipeStream)
        $this.Runspace.SessionStateProxy.SetVariable("isConnected", [ref]$this.IsConnected)

        $this.PowerShell = [powershell]::Create()
        $this.PowerShell.Runspace = $this.Runspace
       
        [void]$this.PowerShell.AddScript({
            try {
                $buffer = New-Object byte[] 1024
                while ($isConnected.Value -and $pipeStream.IsConnected) {
                    if ($pipeStream.CanRead) {
                        $bytesRead = $pipeStream.Read($buffer, 0, 1024)
                        if ($bytesRead -gt 0) {
                            $message = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $bytesRead)
                            $sharedData.message = $message
                        }
                    }
                    Start-Sleep -Milliseconds 100
                }
            }
            catch {
                $isConnected.Value = $false
            }
            finally {
                Write-Host "Message receiver stopped"
            }
        })
       
        $this.IsRunning = $true
        $this.PowerShell.BeginInvoke()
    }

    # Tells our flags to turn off and disposes of the pipestream.
    # This will also terminate the runspace since it will Throw and
    # "die"
    [void] Disconnect() {
        $this.IsConnected = $false
        $this.IsRunning = $false
       
        if ($null -ne $this.PipeStream) {
            $this.PipeStream.Close()
            $this.PipeStream.Dispose()
        }
    }
}

# This is the pipe client. It is the receiver in the handshake protocol.
# Implemented exactly like the server.
# It also works exactly like the server sending and receiving wise.
# This should be disposed of first, before the server if resources are cleaned up.
# Else the script this is running in will throw an error.
class PipeClient {
    [System.IO.Pipes.NamedPipeClientStream]$PipeStream
    [string]$PipeName
    [string]$ServerName
    [System.Management.Automation.Runspaces.Runspace]$Runspace
    [System.Management.Automation.PowerShell]$PowerShell
    [bool]$IsConnected
    [bool]$IsRunning
    [hashtable]$SharedData

    PipeClient([string]$serverName = ".", [string]$pipeName) {
        $this.PipeName = $pipeName
        $this.ServerName = $serverName
        $this.PipeStream = New-Object System.IO.Pipes.NamedPipeClientStream($serverName, $pipeName, [PipeDirection]::InOut, [PipeOptions]::Asynchronous)
        $this.IsConnected = $false
        $this.IsRunning = $false
        $this.SharedData = [hashtable]::Synchronized(@{ message = "" })
    }

    # Establish connection with server, this is a blocking call and will freeze until
    # a connection with a server is made, or it times out, input is optional, default is 5000ms
    [bool] TryToConnect([int]$timeoutMs = 5000) {
        try {
            Write-Host "Connecting to pipe server: $($this.ServerName)\$($this.PipeName)"
            $this.PipeStream.Connect($timeoutMs)
            $this.IsConnected = $this.PipeStream.IsConnected
            if ($this.IsConnected) {
                Write-Host "Connected to pipe server: $($this.ServerName)\$($this.PipeName)"
            } else {
                Write-Host "Failed to connect to pipe server"
            }
            return $this.IsConnected
        }
        catch {
            Write-Host "Connection error: $_"
            return $false
        }
    }

    # This is more of a utility function to clear the message after reading it
    [void] ResetMessage() {
        $this.SharedData["message"] = ""
    }

    # Writes to the pipe, this is a blocking call
    [void] WriteMessage([string]$message) {
        if (-not $this.IsConnected) {
            throw "Pipe is not connected. Cannot send message."
        }

        $bytes = [Encoding]::UTF8.GetBytes($message)
        $this.PipeStream.Write($bytes, 0, $bytes.Length)
        $this.PipeStream.Flush()
    }

    # Reads from the hashtable, not the pipe, this is not a blocking call
    [string] ReadMessage() {
        if (-not $this.IsConnected) {
            throw "Pipe is not connected. Cannot read message."
        }
        return $this.SharedData.message
    }

    # This makes a runspace that continuously reads from the pipe in the background
    # The data the runspace reads from the pipe is stored to the hashtable SharedData
    # in it's value "message"
    # This means the runspace will always hang on "Read" such that messages are always
    # read right away, and it means we don't have to block the main thread to read messages
    [void] CreateMessageReceiver() {
        if ($this.IsRunning) {
            Write-Host "Message receiver is already running"
            return
        }

        $this.Runspace = [runspacefactory]::CreateRunspace()
        $this.Runspace.Open()
        $this.Runspace.SessionStateProxy.SetVariable("sharedData", $this.sharedData)
        $this.Runspace.SessionStateProxy.SetVariable("pipeStream", $this.PipeStream)
        $this.Runspace.SessionStateProxy.SetVariable("isConnected", [ref]$this.IsConnected)

        $this.PowerShell = [powershell]::Create()
        $this.PowerShell.Runspace = $this.Runspace
       
        [void]$this.PowerShell.AddScript({
            try {
                $buffer = New-Object byte[] 1024
                while ($isConnected.Value -and $pipeStream.IsConnected) {
                    if ($pipeStream.CanRead) {
                        $bytesRead = $pipeStream.Read($buffer, 0, 1024)
                        if ($bytesRead -gt 0) {
                            $message = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $bytesRead)
                            $sharedData.message = $message
                            
                        }
                    }
                    Start-Sleep -Milliseconds 100
                }
            }
            catch {
                $isConnected.Value = $false
            }
            finally {
                Write-Host "Message receiver stopped"
            }
        })
       
        $this.IsRunning = $true
        $this.PowerShell.BeginInvoke()
    }

    # Tells our flags to turn off and disposes of the pipestream.
    # This will also terminate the runspace since it will Throw and
    # "die"
    [void] Disconnect() {
        $this.IsConnected = $false
        $this.IsRunning = $false
       
        if ($null -ne $this.PipeStream) {
            $this.PipeStream.Close()
            $this.PipeStream.Dispose()
        }
    }
}



# This has been a learning project, feel free to use in your own projects if it is helpful
# or can be of use.

# - Mats Anders Soot Larsen