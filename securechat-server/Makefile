BINARY = securechat-server

build:
	go build -o $(BINARY) ./main.go

build-linux:
	GOOS=linux GOARCH=amd64 go build -o $(BINARY)-linux-amd64 ./main.go

build-windows:
	GOOS=windows GOARCH=amd64 go build -o $(BINARY)-windows-amd64.exe ./main.go

run:
	go run ./main.go --config config.toml

test:
	go test ./...

clean:
	rm -f $(BINARY) $(BINARY)-linux-amd64 $(BINARY)-windows-amd64.exe data.db

.PHONY: build build-linux build-windows run test clean
