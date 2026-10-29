// Copyright (c) MoMo Agent contributors
// SPDX-License-Identifier: BSD-3-Clause
//go:build darwin || ios

package main

import (
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"tailscale.com/net/netmon"
	"tailscale.com/net/netns"
	"tailscale.com/util/eventbus"
	"testing"
	"time"
)

func TestMoMoAppleProxyResolution(t *testing.T) {
	for _, test := range []struct {
		name, target, mode, address, want string
		calls                             int
	}{
		{"system HTTPS", "https://controlplane.tailscale.com/key", "system", "", "http://127.0.0.1:7890", 1},
		{"system upgrade", "http://controlplane.tailscale.com/ts2021", "system", "", "http://127.0.0.1:7890", 1},
		{"manual", "https://controlplane.tailscale.com/key", "manual", "http://proxy.invalid:8080", "http://proxy.invalid:8080", 0},
		{"direct", "https://controlplane.tailscale.com/key", "direct", "", "", 0},
		{"loopback", "http://127.0.0.1:1234", "manual", "http://proxy.invalid:8080", "", 0},
		{"IPv6 loopback", "http://[::1]:1234", "system", "", "", 0},
		{"localhost", "http://localhost:1234", "system", "", "", 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			calls := 0
			u, _ := url.Parse(test.target)
			got, err := resolveAppleProxy(u, appleProxyPolicy{test.mode, test.address}, func(*url.URL) (*url.URL, error) { calls++; return url.Parse("http://127.0.0.1:7890") })
			actual := ""
			if got != nil {
				actual = got.String()
			}
			if err != nil || actual != test.want || calls != test.calls {
				t.Fatalf("proxy=%q calls=%d err=%v", actual, calls, err)
			}
		})
	}
}

func TestMoMoAppleProxyChangesAndFailure(t *testing.T) {
	t.Setenv("HTTP_PROXY", "http://127.0.0.1:1")
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:1")
	t.Setenv("NO_PROXY", "*")
	u, _ := url.Parse("https://controlplane.tailscale.com/key")
	current := "http://127.0.0.1:7890"
	resolver := func(*url.URL) (*url.URL, error) {
		if current == "" {
			return nil, nil
		}
		return url.Parse(current)
	}
	for _, value := range []string{current, "http://127.0.0.1:7891", ""} {
		current = value
		got, err := resolveAppleProxy(u, appleProxyPolicy{}, resolver)
		actual := ""
		if got != nil {
			actual = got.String()
		}
		if err != nil || actual != value {
			t.Fatal("did not follow updated system proxy")
		}
	}
	want := errors.New("proxy configuration unavailable")
	got, err := resolveAppleProxy(u, appleProxyPolicy{}, func(*url.URL) (*url.URL, error) { return nil, want })
	if got != nil || !errors.Is(err, want) {
		t.Fatal("proxy errors must not silently become direct connections")
	}
}

func TestMoMoAppleProxyValidation(t *testing.T) {
	for _, value := range []string{"http://127.0.0.1:7890", "https://proxy.example:443/", "http://[::1]:1080"} {
		if _, err := parseAppleProxy("manual", value); err != nil {
			t.Fatal(err)
		}
	}
	for _, value := range []string{"", "127.0.0.1:7890", "http://proxy", "http://proxy:0", "http://proxy:65536", "ftp://proxy:80", "socks5://proxy:1080", "http://user:secret@proxy:80", "http://proxy:80/path", "http://proxy:80?x=1", "http://proxy:80#x"} {
		if _, err := parseAppleProxy("manual", value); err == nil {
			t.Fatalf("accepted invalid address %q", value)
		}
	}
	if _, err := parseAppleProxy("unknown", ""); err == nil {
		t.Fatal("accepted invalid mode")
	}
}

func TestMoMoAppleProxyRecoversWithoutClientRestart(t *testing.T) {
	// Run this binary with a dead ALL_PROXY to catch nested/cached SOCKS routes.
	if os.Getenv("ALL_PROXY") != "" || os.Getenv("all_proxy") != "" {
		t.Fatal("nested proxy was not removed")
	}
	mon, err := netmon.New(eventbus.New(), t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	defer mon.Close()
	dial := netns.NewDialer(t.Logf, mon)
	dead, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	current := "http://" + dead.Addr().String()
	dead.Close()
	transport := &http.Transport{DialContext: dial.DialContext, Proxy: func(r *http.Request) (*url.URL, error) {
		return resolveAppleProxy(r.URL, appleProxyPolicy{}, func(*url.URL) (*url.URL, error) { return url.Parse(current) })
	}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 2 * time.Second}
	if resp, err := client.Get("http://control.invalid/key"); err == nil {
		resp.Body.Close()
		t.Fatal("dead proxy bypassed to direct")
	}
	for _, marker := range []string{"recovered", "switched"} {
		proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, marker) }))
		current = proxy.URL
		resp, err := client.Get("http://control.invalid/key")
		if err != nil {
			proxy.Close()
			t.Fatal(err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		proxy.Close()
		if string(body) != marker {
			t.Fatal("response did not use current proxy")
		}
	}
}
