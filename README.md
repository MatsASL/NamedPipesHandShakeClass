# NamedPipesHandShakeClass
This contains named pipe server and client classes that make reading messages non-blocking, and smoother for hanshake protocols in projects that wants to "do things" while also being able to receive messages from other processes, and only be blocked while writing to the pipe.
