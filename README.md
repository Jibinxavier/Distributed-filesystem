# Distributed-filesystem

##### Security Service
1. Client asks for the public key, (ideally the client would already know). It uses this key to encrypt its first interactions with authentication server.
2. A user signs up with a user_name and password
3. It then authenticates itself by calling "sign in", which in turn returns a message encrypted with client pass. 

    3.1 The message contains encCLIENT_PASS (generated session key ,encSHARED_SCERET(generated session key, expiry date)) 
4. The client uses this token to communicate with other services
##### Lock service
1. Authenticates user
2. Locks file if available and returns a tuple (inqueue, lockavailable)
3. If it is already locked, the user is added to the queue
4. When a user unlocks, the server assigns the lock to the user in the queue if there is one, and notifies it.

##### Directory service

##### Fileserver service
 The directory will point client to primary server for writes and reads to the secondary ones.
1. Stores the files
2. Starts by registering itself then it regularly sends heartbeats to the directory service. 
3. Each fileserver represent a directory. The directory name is passed in an environment variable
4. Asynchronously sends the copy (if primary copy)