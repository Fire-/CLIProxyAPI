package api

import (
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"github.com/gin-gonic/gin"
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

// middleware counts the requests of the group it is attached to.
func (g *inflightGauge) middleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		if strings.EqualFold(c.GetHeader("Upgrade"), "websocket") {
			c.Next()
			return
		}
		g.enter()
		defer g.leave()
		c.Next()
	}
}

// handleInflight reports the gauge over the management API. It is registered inline
// rather than on the management handler because the gauge belongs to the server that
// serves the counted routes.
func (s *Server) handleInflight(c *gin.Context) {
	active, busySeconds := s.inflight.snapshot()
	c.JSON(http.StatusOK, gin.H{"inflight": active, "busy_seconds": busySeconds})
}
