.PHONY: build run test clean install uninstall

build:
	swift build -c release

run:
	swift run fsmond --db ./data/fsmon.db --log-level debug

test:
	swift test

clean:
	swift package clean
	rm -rf .build data

install: build
	@test "$$(id -u)" = 0 || (echo "Run sudo make install"; exit 1)
	install -d -m 755 /usr/local/bin
	install -d -m 700 /var/db/fsmond
	install -m 755 .build/release/fsmond /usr/local/bin/fsmond
	install -m 644 packaging/com.hackwestex.fsmond.plist /Library/LaunchDaemons/com.hackwestex.fsmond.plist
	chown root:wheel /usr/local/bin/fsmond /var/db/fsmond /Library/LaunchDaemons/com.hackwestex.fsmond.plist
	launchctl bootstrap system /Library/LaunchDaemons/com.hackwestex.fsmond.plist

uninstall:
	@test "$$(id -u)" = 0 || (echo "Run sudo make uninstall"; exit 1)
	launchctl bootout system /Library/LaunchDaemons/com.hackwestex.fsmond.plist
	rm -f /usr/local/bin/fsmond /Library/LaunchDaemons/com.hackwestex.fsmond.plist
	@echo "Database retained at /var/db/fsmond"
