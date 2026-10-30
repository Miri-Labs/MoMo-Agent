// Copyright (c) MoMoAgent contributors. SPDX-License-Identifier: BSD-3-Clause
package main

import "C"
import (
	"context"
	"errors"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strconv"
	"sync"
	"time"
)

var momoProxies sync.Map // server handle -> *http.Server

//export TsnetMoMoServe
func TsnetMoMoServe(sd C.int, localPort C.int) C.int {
	s := getServer(sd)
	if s == nil {
		return -1
	}
	if localPort < 1 || localPort > 65535 {
		return s.recErr(errors.New("invalid loopback port"))
	}
	if _, exists := momoProxies.Load(sd); exists {
		return 0
	}
	// HTTP stays inside the encrypted tailnet. No host socket, DNS or certificate setup.
	ln, err := s.s.Listen("tcp", ":8767")
	if err != nil {
		return s.recErr(err)
	}
	srv := momoProxy(int(localPort))
	if _, loaded := momoProxies.LoadOrStore(sd, srv); loaded {
		ln.Close()
		return 0
	}
	go func() { _ = srv.Serve(ln); momoProxies.CompareAndDelete(sd, srv) }()
	return 0
}

func momoProxy(localPort int) *http.Server {
	target, _ := url.Parse("http://127.0.0.1:" + strconv.Itoa(localPort))
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.FlushInterval = -1
	proxy.Transport = &http.Transport{Proxy: nil, MaxIdleConnsPerHost: 16, ResponseHeaderTimeout: 30 * time.Second}
	return &http.Server{Handler: proxy, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 90 * time.Second, MaxHeaderBytes: 32768}
}

//export TsnetMoMoStopServe
func TsnetMoMoStopServe(sd C.int) C.int {
	if value, exists := momoProxies.LoadAndDelete(sd); exists {
		srv := value.(*http.Server)
		_ = srv.Close()
		if p, ok := srv.Handler.(*httputil.ReverseProxy); ok {
			p.Transport.(*http.Transport).CloseIdleConnections()
		}
	}
	return 0
}

//export TsnetMoMoLogout
func TsnetMoMoLogout(sd C.int) C.int {
	s := getServer(sd)
	if s == nil {
		return -1
	}
	lc, err := s.s.LocalClient()
	if err != nil {
		return s.recErr(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return s.recErr(lc.Logout(ctx))
}
