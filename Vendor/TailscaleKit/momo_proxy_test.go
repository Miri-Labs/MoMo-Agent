package main

import (
	"bufio"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"
)

func TestMoMoProxyStreamsAndPreservesRequest(t *testing.T) {
	release := make(chan struct{})
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.RequestURI() != "/runs/test/events?after=1" || r.Header.Get("Authorization") != "Bearer synthetic" || r.Header.Get("Last-Event-ID") != "1" || r.Header.Get("Idempotency-Key") != "same-run" {
			t.Error("request identity or resume headers changed")
		}
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "id: 2\ndata: continuing\n\n")
		w.(http.Flusher).Flush()
		<-release
		fmt.Fprint(w, "event: done\ndata: completed\n\n")
	}))
	defer backend.Close()
	_, port, _ := net.SplitHostPort(backend.Listener.Addr().String())
	number, _ := strconv.Atoi(port)
	proxy := momoProxy(number)
	front := httptest.NewServer(proxy.Handler)
	defer front.Close()
	// A configured environment proxy must never receive MoMo's local credentials.
	t.Setenv("HTTP_PROXY", "http://127.0.0.1:1")
	request, _ := http.NewRequest("GET", front.URL+"/runs/test/events?after=1", nil)
	request.Header.Set("Authorization", "Bearer synthetic")
	request.Header.Set("Last-Event-ID", "1")
	request.Header.Set("Idempotency-Key", "same-run")
	client := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{Proxy: nil}}
	response, err := client.Do(request)
	if err != nil {
		close(release)
		t.Fatal(err)
	}
	defer response.Body.Close()
	first := make(chan string, 1)
	reader := bufio.NewReader(response.Body)
	go func() { line, _ := reader.ReadString('\n'); first <- line }()
	select {
	case line := <-first:
		close(release)
		if line != "id: 2\n" {
			t.Fatalf("bad first event: %q", line)
		}
	case <-time.After(2 * time.Second):
		close(release)
		t.Fatal("SSE buffered until task completion")
	}
}
