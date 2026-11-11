package api

import (
	"net/http"
	"sync/atomic"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
)

// inflightGauge counts the proxy requests a server is serving right now, so a
// supervisor can tell an idle hub from a busy one before it stops the process.
//
// A request is counted for as long as its handler runs, streaming included: the count
// drops only when the response is complete, which is the moment a restarter cares
// about. Upstream's shutdown closes connections immediately without draining
// (Server.Stop calls http.Server.Close), so anything in flight when the process stops
// is lost - this gauge is how an outside supervisor avoids that.
//
// WebSocket upgrades are deliberately not counted: a session lasts as long as its
// client wants, so counting one would report a busy hub for hours and hold every
// restart back to its timeout.
type inflightGauge struct {
	active atomic.Int64
	// since is the unix second the gauge left zero, or 0 while it is idle.
	since atomic.Int64
}

func (g *inflightGauge) enter() {
	if g.active.Add(1) == 1 {
		g.since.Store(time.Now().Unix())
	}
}

func (g *inflightGauge) leave() {
	if g.active.Add(-1) == 0 {
		g.since.Store(0)
	}
}

// snapshot reports the active count and, while busy, how many seconds the gauge has
// been busy. Both are approximate under concurrency: a request arriving exactly as the
// previous last one finishes can briefly report a busy gauge whose start is unknown,
// which is reported as zero seconds rather than as a negative age.
func (g *inflightGauge) snapshot() (active int64, busySeconds int64) {
	active = g.active.Load()
	if active <= 0 {
		return 0, 0
	}
	since := g.since.Load()
	if since <= 0 {
		return active, 0
	}
	if elapsed := time.Now().Unix() - since; elapsed > 0 {
		return active, elapsed
	}
	return active, 0
}

// middleware counts every request on the routes it is installed on. Install it on each
// proxy surface (see server_routes.go); management, health and callback routes stay
// uncounted, so a supervisor's own probing is not mistaken for work.
func (g *inflightGauge) middleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		if isWebsocketUpgrade(c) {
			c.Next()
			return
		}
		g.enter()
		defer g.leave()
		c.Next()
	}
}

// isWebsocketUpgrade reports whether the request is a websocket handshake. Upgrading
// requires a GET (RFC 6455) - gorilla answers every other method with 405 - so a POST that
// carries the headers is still counted: skipping it on the headers alone would let the gauge
// report an idle hub with that call mid-flight, the one mistake the gate exists to prevent.
// The header test is gorilla's own, which compares tokens rather than whole values, so
// `Upgrade: websocket, h2c` is excluded too. Counting that session would pin the gauge above
// zero for as long as the client holds it, and every restart would wait out its cap.
func isWebsocketUpgrade(c *gin.Context) bool {
	if c.Request.Method != http.MethodGet {
		return false
	}
	return websocket.IsWebSocketUpgrade(c.Request)
}

// handleInflight reports the gauge over the management API. It is registered inline
// rather than on the management handler because the gauge belongs to the server that
// serves the counted routes.
func (s *Server) handleInflight(c *gin.Context) {
	active, busySeconds := s.inflight.snapshot()
	c.JSON(http.StatusOK, gin.H{"inflight": active, "busy_seconds": busySeconds})
}
