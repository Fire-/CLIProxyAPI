package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/gin-gonic/gin"
)

// A request counts while it is being served, including while it streams, and stops
// counting once the response is complete.
func TestInflightGaugeCountsServingRequests(t *testing.T) {
	gin.SetMode(gin.TestMode)
	var gauge inflightGauge
	release := make(chan struct{})
	entered := make(chan struct{}, 4)

	router := gin.New()
	router.Use(gauge.middleware())
	router.GET("/work", func(c *gin.Context) {
		entered <- struct{}{}
		<-release
		c.Status(http.StatusOK)
	})

	var serving sync.WaitGroup
	for i := 0; i < cap(entered); i++ {
		serving.Add(1)
		go func() {
			defer serving.Done()
			router.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/work", nil))
		}()
	}
	for i := 0; i < cap(entered); i++ {
		<-entered
	}
	if active, _ := gauge.snapshot(); active != int64(cap(entered)) {
		t.Fatalf("expected %d in-flight requests, got %d", cap(entered), active)
	}

	close(release)
	serving.Wait()
	if active, busy := gauge.snapshot(); active != 0 || busy != 0 {
		t.Fatalf("expected an idle gauge after every response finished, got active=%d busy=%d", active, busy)
	}
}

// A websocket session must not hold the gauge up for the life of its client.
func TestInflightGaugeIgnoresWebsocketUpgrades(t *testing.T) {
	gin.SetMode(gin.TestMode)
	var gauge inflightGauge
	release := make(chan struct{})
	entered := make(chan struct{}, 1)

	router := gin.New()
	router.Use(gauge.middleware())
	router.GET("/ws", func(c *gin.Context) {
		entered <- struct{}{}
		<-release
		c.Status(http.StatusOK)
	})

	go func() {
		request := httptest.NewRequest(http.MethodGet, "/ws", nil)
		request.Header.Set("Upgrade", "websocket")
		router.ServeHTTP(httptest.NewRecorder(), request)
	}()
	<-entered
	if active, _ := gauge.snapshot(); active != 0 {
		t.Fatalf("a websocket upgrade must not count as in-flight, got %d", active)
	}
	close(release)
}

func TestHandleInflightReportsTheGauge(t *testing.T) {
	gin.SetMode(gin.TestMode)
	server := &Server{}
	server.inflight.enter()
	defer server.inflight.leave()

	router := gin.New()
	router.GET("/v0/management/inflight", server.handleInflight)
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/v0/management/inflight", nil))

	if recorder.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", recorder.Code)
	}
	if body := recorder.Body.String(); !strings.Contains(body, `"inflight":1`) {
		t.Fatalf("expected the gauge to report one in-flight request, got %s", body)
	}
}
