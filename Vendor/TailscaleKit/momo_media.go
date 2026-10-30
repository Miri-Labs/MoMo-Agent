// Copyright (c) MoMo Agent contributors. SPDX-License-Identifier: BSD-3-Clause
package main

/*
#include <stdlib.h>
*/
import "C"
import (
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"time"
)

// A session-scoped datagram bridge lets native libwebrtc use the embedded
// tailnet without an OS VPN. It never exposes a host listener to the LAN and
// never falls back to the ordinary network. DTLS/SRTP remain end-to-end.
type momoMediaBridge struct {
	owner          int
	local          *net.UDPConn
	tail           net.PacketConn
	mu             sync.RWMutex
	source, remote netip.AddrPort
	once           sync.Once
}

var momoMedia = struct {
	sync.Mutex
	items map[int]*momoMediaBridge
}{items: make(map[int]*momoMediaBridge)}
var momoMediaID atomic.Int32

func (b *momoMediaBridge) close() { b.once.Do(func() { b.local.Close(); b.tail.Close() }) }
func (b *momoMediaBridge) endpoints() (netip.AddrPort, netip.AddrPort) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.source, b.remote
}
func (b *momoMediaBridge) pump(toTail bool) {
	defer b.close()
	buf := make([]byte, 65536)
	for {
		var n int
		var from net.Addr
		var err error
		if toTail {
			n, from, err = b.local.ReadFrom(buf)
		} else {
			n, from, err = b.tail.ReadFrom(buf)
		}
		if err != nil {
			return
		}
		src, remote := b.endpoints()
		address, err := netip.ParseAddrPort(from.String())
		if err != nil || !src.IsValid() || !remote.IsValid() {
			continue
		}
		if toTail {
			if address != src {
				continue
			}
			_ = b.tail.SetWriteDeadline(time.Now().Add(500 * time.Millisecond))
			_, err = b.tail.WriteTo(buf[:n], net.UDPAddrFromAddrPort(remote))
		} else {
			if address != remote {
				continue
			}
			_ = b.local.SetWriteDeadline(time.Now().Add(500 * time.Millisecond))
			_, err = b.local.WriteToUDPAddrPort(buf[:n], src)
		}
		// Congestion drops a datagram; WebRTC owns loss recovery and rate control.
		if err != nil {
			if ne, ok := err.(net.Error); !ok || !ne.Timeout() {
				return
			}
		}
	}
}
func localMediaAddress(ip netip.Addr) bool {
	if ip.IsLoopback() {
		return ip.Is4()
	}
	list, _ := net.InterfaceAddrs()
	for _, a := range list {
		p, err := netip.ParsePrefix(a.String())
		if err == nil && p.Addr() == ip {
			return true
		}
	}
	return false
}
func (b *momoMediaBridge) configure(source, remote netip.AddrPort) error {
	if !source.IsValid() || source.Port() == 0 || !source.Addr().Is4() || !localMediaAddress(source.Addr()) ||
		!remote.IsValid() || remote.Port() == 0 || !netip.MustParsePrefix("100.64.0.0/10").Contains(remote.Addr()) {
		return errors.New("invalid media endpoints")
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.source.IsValid() && (b.source != source || b.remote != remote) {
		return errors.New("media route is immutable")
	}
	b.source = source
	b.remote = remote
	return nil
}

//export TsnetMoMoMediaOpen
func TsnetMoMoMediaOpen(sd C.int, out **C.char) C.int {
	s := getServer(sd)
	if s == nil || out == nil {
		return -1
	}
	*out = nil
	momoMedia.Lock()
	defer momoMedia.Unlock()
	count := 0
	for _, b := range momoMedia.items {
		if b.owner == int(sd) {
			count++
		}
	}
	if count >= 4 {
		return s.recErr(errors.New("too many media sessions"))
	}
	ip, _ := s.s.TailscaleIPs()
	if !ip.IsValid() {
		return s.recErr(errors.New("tailnet is not ready"))
	}
	tail, err := s.s.ListenPacket("udp4", netip.AddrPortFrom(ip, 0).String())
	if err != nil {
		return s.recErr(err)
	}
	local, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		tail.Close()
		return s.recErr(err)
	}
	b := &momoMediaBridge{owner: int(sd), local: local, tail: tail}
	id := int(momoMediaID.Add(1))
	momoMedia.items[id] = b
	value, _ := json.Marshal(map[string]any{"id": id, "local": local.LocalAddr().String(), "tailnet": tail.LocalAddr().String()})
	*out = C.CString(string(value))
	go b.pump(true)
	go b.pump(false)
	return 0
}

//export TsnetMoMoMediaConfigure
func TsnetMoMoMediaConfigure(sd C.int, id C.int, source *C.char, remote *C.char) C.int {
	s := getServer(sd)
	if s == nil || source == nil || remote == nil {
		return -1
	}
	momoMedia.Lock()
	b := momoMedia.items[int(id)]
	momoMedia.Unlock()
	if b == nil || b.owner != int(sd) {
		return s.recErr(errors.New("unknown media session"))
	}
	src, e1 := netip.ParseAddrPort(C.GoString(source))
	dst, e2 := netip.ParseAddrPort(C.GoString(remote))
	if e1 != nil || e2 != nil {
		return s.recErr(errors.New("invalid media endpoint"))
	}
	return s.recErr(b.configure(src, dst))
}

//export TsnetMoMoMediaClose
func TsnetMoMoMediaClose(sd C.int, id C.int) C.int {
	momoMedia.Lock()
	b := momoMedia.items[int(id)]
	if b != nil && b.owner == int(sd) {
		delete(momoMedia.items, int(id))
	} else {
		b = nil
	}
	momoMedia.Unlock()
	if b != nil {
		b.close()
	}
	return 0
}
func closeMoMoMedia(sd C.int) {
	momoMedia.Lock()
	defer momoMedia.Unlock()
	for id, b := range momoMedia.items {
		if b.owner == int(sd) {
			delete(momoMedia.items, id)
			b.close()
		}
	}
}
