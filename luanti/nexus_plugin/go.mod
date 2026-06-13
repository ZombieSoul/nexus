module nexus

go 1.22

require github.com/HimbeerserverDE/mt-multiserver-proxy v0.0.0-20260510165802-6421f82da4a6

require (
	github.com/HimbeerserverDE/mt v0.0.0-20260501223507-c73641265239 // indirect
	github.com/HimbeerserverDE/srp v0.0.0 // indirect
	github.com/klauspost/compress v1.17.8 // indirect
	github.com/lib/pq v1.10.9 // indirect
	github.com/mattn/go-sqlite3 v1.14.22 // indirect
)

replace github.com/HimbeerserverDE/mt-multiserver-proxy => ../proxy
