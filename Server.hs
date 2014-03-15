import JobServer

port :: PortID
port = PortNumber 2228

workers :: [Worker]
workers = [localWorker, localWorker, localWorker, localWorker]

main :: IO ()    
main = start port workers
