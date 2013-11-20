import JobServer

port :: PortID
port = PortNumber 2228

workers :: [Worker]
workers = [localWorker, localWorker, sshWorker "ben-server" "/mnt/data"]

main :: IO ()    
main = start port workers
