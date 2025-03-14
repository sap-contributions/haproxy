#!/bin/sh

check() {
	${HAPROXY_PROGRAM} -vv | grep -E '^Unit tests list :' | grep -q "quic"
}

run() {
	${HAPROXY_PROGRAM} -U quic_enc
}

case "$1" in
	"check")
		check
	;;
	"run")
		run
	;;
esac
