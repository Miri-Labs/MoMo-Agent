package main

import (
	"net"
	"net/netip"
	"testing"
	"time"
)

func udpFixture(t *testing.T) *net.UDPConn {
	t.Helper()
	c, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}
func TestMediaRouteValidation(t *testing.T) {
	b := &momoMediaBridge{}
	source := netip.MustParseAddrPort("127.0.0.1:9000")
	good := netip.MustParseAddrPort("100.64.0.1:9001")
	for _, remote := range []string{"8.8.8.8:53", "192.168.0.1:123", "100.63.0.1:123", "100.128.0.1:123", "100.64.0.1:0", "[fd00::1]:123"} {
		if b.configure(source, netip.MustParseAddrPort(remote)) == nil {
			t.Fatalf("accepted %s", remote)
		}
	}
	if b.configure(netip.MustParseAddrPort("8.8.8.8:99"), good) == nil {
		t.Fatal("accepted nonlocal source")
	}
	if err := b.configure(source, good); err != nil {
		t.Fatal(err)
	}
	if err := b.configure(source, good); err != nil {
		t.Fatal(err)
	}
	if b.configure(source, netip.MustParseAddrPort("100.64.0.2:9001")) == nil {
		t.Fatal("route changed")
	}
}
func TestMediaPumpPinsBothEndpointsAndCloses(t *testing.T) {
	source, remote, intruder := udpFixture(t), udpFixture(t), udpFixture(t)
	b := &momoMediaBridge{local: udpFixture(t), tail: udpFixture(t), source: source.LocalAddr().(*net.UDPAddr).AddrPort(), remote: remote.LocalAddr().(*net.UDPAddr).AddrPort()}
	done := make(chan bool, 2)
	go func() { b.pump(true); done <- true }()
	go func() { b.pump(false); done <- true }()
	payload := []byte("encrypted-datagram-fixture")
	receive := func(c *net.UDPConn, want bool) {
		t.Helper()
		c.SetReadDeadline(time.Now().Add(80 * time.Millisecond))
		buf := make([]byte, 100)
		n, _, err := c.ReadFrom(buf)
		if want {
			if err != nil || string(buf[:n]) != string(payload) {
				t.Fatalf("receive: %d %v", n, err)
			}
		} else if err == nil {
			t.Fatal("unexpected forwarded datagram")
		}
	}
	intruder.WriteTo(payload, b.local.LocalAddr())
	receive(remote, false)
	source.WriteTo(payload, b.local.LocalAddr())
	receive(remote, true)
	intruder.WriteTo(payload, b.tail.LocalAddr())
	receive(source, false)
	remote.WriteTo(payload, b.tail.LocalAddr())
	receive(source, true)
	b.close()
	b.close()
	for i := 0; i < 2; i++ {
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("pump leaked on close")
		}
	}
}
