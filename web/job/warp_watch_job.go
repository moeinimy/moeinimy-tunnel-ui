package job

import "github.com/mhsanaei/3x-ui/v2/web/service"

// WarpWatchJob reconnects a WARP daemon that has dropped. See WarpWatchService
// for why a dropped connection is invisible without it: everything still reads as
// configured, and only the services WARP was there for stop working.
type WarpWatchJob struct {
	warp service.WarpWatchService
}

func NewWarpWatchJob() *WarpWatchJob { return new(WarpWatchJob) }

func (j *WarpWatchJob) Run() { j.warp.Run() }
