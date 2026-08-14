package job

import (
	"github.com/mhsanaei/3x-ui/v2/logger"
	"github.com/mhsanaei/3x-ui/v2/web/service"
)

// WarpLicenseJob keeps the panel's WARP on a live WARP+ licence.
//
// It is deliberately quiet. A licence that is healthy needs nothing, however
// often the published key list changes, so this only LOOKS — one cheap read of
// the account — and does nothing else until that read says the licence has
// lapsed to the free tier or is nearly spent.
//
// That restraint is not just tidiness. Every key tested costs a registration at
// Cloudflare and one of that key's five device slots, and the key pool is shared
// with everyone else using the same public list. Scanning on a schedule rather
// than on a need would burn the very keys this depends on.
type WarpLicenseJob struct {
	keys service.WarpKeyService
}

func NewWarpLicenseJob() *WarpLicenseJob { return new(WarpLicenseJob) }

func (j *WarpLicenseJob) Run() {
	if j.keys.ScanState().Running {
		return // a scan is already under way, started here or by the operator
	}
	need, why := j.keys.NeedsRenewal()
	if !need {
		return
	}
	logger.Info("warp: ", why, "; looking for a fresh WARP+ key")
	j.keys.Scan(true, 40)
}
