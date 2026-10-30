// Copyright (c) MoMo Agent contributors
// SPDX-License-Identifier: BSD-3-Clause

//go:build darwin || ios

package main

/*
#cgo LDFLAGS: -framework CFNetwork -framework CoreFoundation
#include <CFNetwork/CFNetwork.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
#include <string.h>

// Read the OS configuration for each destination. CopyProxiesForURL applies
// the system bypass list; it does not execute PAC scripts.
static int momo_system_proxy(const char *target, char **host, int *port) {
    CFURLRef url = CFURLCreateWithBytes(NULL, (const UInt8 *)target, strlen(target), kCFStringEncodingUTF8, NULL);
    if (!url) return -1;
    CFDictionaryRef settings = CFNetworkCopySystemProxySettings();
    if (!settings) { CFRelease(url); return 0; }
    CFArrayRef proxies = CFNetworkCopyProxiesForURL(url, settings);
    CFRelease(settings); CFRelease(url);
    if (!proxies) return -1;
    int result = 0;
    if (CFArrayGetCount(proxies) > 0) {
        CFDictionaryRef proxy = CFArrayGetValueAtIndex(proxies, 0);
        CFStringRef type = CFDictionaryGetValue(proxy, kCFProxyTypeKey);
        if (!type || CFEqual(type, kCFProxyTypeNone)) result = 0;
        else if (CFEqual(type, kCFProxyTypeHTTP) || CFEqual(type, kCFProxyTypeHTTPS)) result = 1;
        else if (CFEqual(type, kCFProxyTypeSOCKS)) result = 2;
        else result = 3; // PAC requires a separate asynchronous resolver.
        if (result == 1 || result == 2) {
            CFStringRef name = CFDictionaryGetValue(proxy, kCFProxyHostNameKey);
            CFNumberRef number = CFDictionaryGetValue(proxy, kCFProxyPortNumberKey);
            if (!name || !number || !CFNumberGetValue(number, kCFNumberIntType, port)) result = -1;
            else {
                CFIndex size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(name), kCFStringEncodingUTF8) + 1;
                *host = malloc(size);
                if (!*host || !CFStringGetCString(name, *host, size, kCFStringEncodingUTF8)) result = -1;
            }
        }
    }
    CFRelease(proxies);
    return result;
}
*/
import "C"

import (
	"errors"
	"net"
	"net/url"
	"os"
	"strconv"
	"sync"
	"syscall"
	"unsafe"

	"golang.org/x/net/http/httpproxy"
	"tailscale.com/net/tshttpproxy"
)

func init() {
	// This native app resolves one proxy at the HTTP transport. netns otherwise
	// wraps even that proxy connection in a second, cached ALL_PROXY SOCKS dialer.
	// Do not inherit a launcher's stale shell route into the application node.
	_ = os.Unsetenv("ALL_PROXY")
	_ = os.Unsetenv("all_proxy")
	// Register before the first tsnet server starts. This changes only the
	// control/DERP HTTP transport, not the tailnet-only application transport.
	if err := tshttpproxy.SetProxyFunc(func(target *url.URL) (*url.URL, error) {
		appleProxy.RLock()
		policy := appleProxy.policy
		appleProxy.RUnlock()
		return resolveAppleProxy(target, policy, systemProxy)
	}); err != nil {
		panic(err)
	}
}

type appleProxyPolicy struct{ mode, address string }

var appleProxy = struct {
	sync.RWMutex
	policy appleProxyPolicy
}{}

//export TsnetMoMoSetProxy
func TsnetMoMoSetProxy(mode, address *C.char) C.int {
	if mode == nil || address == nil {
		return C.int(syscall.EINVAL)
	}
	policy, err := parseAppleProxy(C.GoString(mode), C.GoString(address))
	if err != nil {
		return C.int(syscall.EINVAL)
	}
	appleProxy.Lock()
	appleProxy.policy = policy
	appleProxy.Unlock()
	return 0
}

func parseAppleProxy(mode, address string) (appleProxyPolicy, error) {
	if mode == "system" || mode == "direct" {
		return appleProxyPolicy{mode: mode}, nil
	}
	u, err := url.Parse(address)
	if mode != "manual" || err != nil || u == nil || u.Hostname() == "" ||
		(u.Scheme != "http" && u.Scheme != "https") ||
		u.User != nil || (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" {
		return appleProxyPolicy{}, errors.New("invalid proxy address")
	}
	port, err := strconv.Atoi(u.Port())
	if err != nil || port < 1 || port > 65535 {
		return appleProxyPolicy{}, errors.New("invalid proxy port")
	}
	u.Path = ""
	return appleProxyPolicy{mode: mode, address: u.String()}, nil
}

func resolveAppleProxy(target *url.URL, policy appleProxyPolicy, system func(*url.URL) (*url.URL, error)) (*url.URL, error) {
	// Loopback always stays local. System destination bypass rules are applied
	// by CFNetwork. Shell HTTP(S)_PROXY and NO_PROXY do not override GUI settings.
	bypass := httpproxy.Config{HTTPProxy: "http://proxy.invalid", HTTPSProxy: "http://proxy.invalid"}
	if proxy, err := bypass.ProxyFunc()(target); proxy == nil || err != nil {
		return nil, err
	}
	if policy.mode == "direct" {
		return nil, nil
	}
	if policy.mode == "manual" {
		return (&httpproxy.Config{HTTPProxy: policy.address, HTTPSProxy: policy.address}).ProxyFunc()(target)
	}
	return system(target)
}

func systemProxy(target *url.URL) (*url.URL, error) {
	raw := C.CString(target.String())
	defer C.free(unsafe.Pointer(raw))
	var host *C.char
	var port C.int
	kind := C.momo_system_proxy(raw, &host, &port)
	if host != nil {
		defer C.free(unsafe.Pointer(host))
	}
	switch kind {
	case 0:
		return nil, nil
	case 1, 2:
		if host == nil || C.GoString(host) == "" || port < 1 || port > 65535 {
			return nil, errors.New("invalid system proxy address")
		}
		scheme := "http" // kCFProxyTypeHTTPS describes an HTTP CONNECT proxy.
		if kind == 2 {
			scheme = "socks5"
		}
		return &url.URL{Scheme: scheme, Host: net.JoinHostPort(C.GoString(host), strconv.Itoa(int(port)))}, nil
	case 3:
		return nil, errors.New("system proxy uses PAC; automatic proxy scripts are not supported by embedded Tailscale")
	default:
		return nil, errors.New("cannot read system proxy configuration")
	}
}
