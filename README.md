# NamedPipesHandShakeClass
This contains named pipe server and client classes that make reading messages non-blocking, and smoother for hanshake protocols in projects that wants to "do things" while also being able to receive messages from other processes, and only be blocked while writing to the pipe.

Example implementation in project:
$pipeServer = [PipeServer]::new("myPipeName")
$pipeServer.WaitForConnection()
$pipeServer.CreateMessageReceiver()
Obs! Order matters here since if you switch the connect and create the runspace is given a pipe that isn't going to work, and it won't let you know until you try to $pipeServer.ReadMessage() and always get ""

Later you can use:
$pipeServer.ReadMessage()
To freely read the latest message that was written to the pipe without blocking the thread.
The class uses a runspace to handle pipestream reading.
This means the pipestream is always blocked at reading the pipestream.
This allows you to have the main thread do other things while it waits for new messages.

The only blocking call after the first three calls to make the server or client is:
$pipeServer.WriteMessage()
Since this writes directly to the pipestream. however there is always going to be someone ready and listening on the other
since the runpace on the other side is always listening, that is unless the pipe is broken.

The runspace on each side is always listening, and waiting for a message, then assigns the value to it's class' hashtable $SharedData.message,
sleeps for 100ms then it's waiting again for new messages.
This gives you some time to read before the message is overwritten, but seing as this is meant for implementing a hanshake protocol you should not
be sending more than one message at a time before an _ACK is sent in return, however the safeguard is still there.

If there is desire to disconnect the pipe server $pipeServer.Disconnect() will set flags to $false and close and disconnect the pipestream.
this results in the runspace closing as well, and is effectively a deconstructor, the class has to be created anew if this is not done as a part of 
exiting the program/script/process that it was instanciated in.

The client should disconnect first before the server.
All examples here work similar with PipeClient.
PipeClient only needs server name as parameter before the name of the pipe:
$pipeClient = [PipeClient]::new(".", "myPipeName")
and tryToConnect can be given other timeout time in ms but is default set to 5000ms

This was a learning project, therefore it is probably not perfect, but it improves on some named pipe limitations.
