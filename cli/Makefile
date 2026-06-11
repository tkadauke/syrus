BINARY := syrus
PREFIX ?= /usr/local

.PHONY: build install test clean

build:
	go build -o bin/$(BINARY) .

install: build
	install -d $(PREFIX)/bin
	install bin/$(BINARY) $(PREFIX)/bin/$(BINARY)

test:
	go test ./...

clean:
	rm -rf bin
