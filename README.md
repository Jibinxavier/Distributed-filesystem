# Distributed-filesystem
## Usage
Current configuration has two clients. The start.sh accepts parameter that will determine number fileserver.
``` bash
./start.sh # start all the services with 1 primary fileserver and 2 secondary
cd client
docker-compose run --service-ports client1 # start client 1
docker-compose run --service-ports client2 # start client 2
```
### Distributed Transparent File Access
The files will be distributed across multiple nodes. 
### Client Service
Act as a proxy between user interface and filesystem. Client will allow users to read file content and write to it. The write encapsulates both opening the file and writing to it. As a result at no point the client will keep the file open.
```docker
 docker run -it -e MONGODB_IP=client_database1 -e MONGODB_DATABASE=USEHASKELLDB client  /usr/local/bin/client-exe 8400
 ```
### Security Service
1. Client asks for the public key, (ideally the client would already know). It uses this key to encrypt its first interactions with authentication server.
2. A user signs up with a user_name and password
3. It then authenticates itself by calling "sign in", which in turn returns a message encrypted with client pass. 

    3.1 The message contains encCLIENT_PASS (generated session key ,encSHARED_SCERET(generated session key, expiry date)) 
4. The client uses this token to communicate with other services
### Lock service
1. Authenticates user
2. Locks file if available and returns a tuple (inqueue, lockavailable)
3. If it is already locked, the user is added to the queue
4. When a user unlocks, the server assigns the lock to the user in the queue if there is one, and notifies it.

### Directory service 
The directory service is the most important components. It has a full view of the status of files, this includes: where files arestored, information about primary and secondary fileservers, health of fileserver, and primary server election.

##### File accesses
jkdbss

##### Managing fileservers

##### Handling transactions

### Fileserver service
 The directory will point client to primary server for writes and reads to the secondary ones.
1. Stores the files
2. Starts by registering itself then it regularly sends heartbeats to the directory service. 
3. Each fileserver represent a directory. The directory name is passed in an environment variable
4. Asynchronously sends the copy (if primary copy)

### Transaction Service
