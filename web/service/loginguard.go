package service

import (
	"sync"
	"time"
)

// LoginGuard stops password guessing at the panel's front door.
//
// The panel had no limit at all: an attacker could try a whole wordlist as fast
// as the network allowed, and the only trace was one Telegram notification per
// attempt — which is how a real break-in arrives buried in its own noise. Rate is
// the entire defence against a weak password, because every other control (a long
// password, a changed port, a web path, 2FA) is something the operator has to have
// already got right.
//
// IP-based, in memory. Deliberately not persisted: a restart clearing the counters
// costs an attacker a fresh start on a window measured in minutes, while a file
// that must be written on every failed attempt is a way to be DoS'd from the login
// form.
type LoginGuard struct{}

const (
	// Failures allowed from one address before it is shut out. High enough that a
	// person mistyping a password twice is never affected.
	loginMaxFailures = 5

	// Failures older than this no longer count, so an address that failed once a
	// week ago starts clean.
	loginFailureWindow = 15 * time.Minute

	// How long a blocked address stays blocked. Doubles for each further block, so
	// a persistent guesser is spending hours per handful of attempts.
	loginBlockBase = 15 * time.Minute
	loginBlockMax  = 24 * time.Hour
)

type loginAttempts struct {
	failures []time.Time
	// blockedUntil is when the current block expires; strikes counts how many
	// blocks this address has earned, which is what makes them escalate.
	blockedUntil time.Time
	strikes      int
}

var loginGuard = struct {
	sync.Mutex
	byIP map[string]*loginAttempts
}{byIP: map[string]*loginAttempts{}}

// BlockedFor reports how long an address must wait, or 0 when it may try now.
func (g *LoginGuard) BlockedFor(ip string) time.Duration {
	if ip == "" {
		return 0
	}
	loginGuard.Lock()
	defer loginGuard.Unlock()
	a := loginGuard.byIP[ip]
	if a == nil {
		return 0
	}
	if left := time.Until(a.blockedUntil); left > 0 {
		return left
	}
	return 0
}

// Fail records a failed attempt and reports the block it caused, if any.
//
// Returns the block duration ONLY on the attempt that triggers it, so the caller
// can say so once instead of on every subsequent rejection.
func (g *LoginGuard) Fail(ip string) time.Duration {
	if ip == "" {
		return 0
	}
	loginGuard.Lock()
	defer loginGuard.Unlock()

	a := loginGuard.byIP[ip]
	if a == nil {
		a = &loginAttempts{}
		loginGuard.byIP[ip] = a
	}
	now := time.Now()

	// Drop failures that have aged out of the window.
	kept := a.failures[:0]
	for _, t := range a.failures {
		if now.Sub(t) < loginFailureWindow {
			kept = append(kept, t)
		}
	}
	a.failures = append(kept, now)

	if len(a.failures) < loginMaxFailures {
		return 0
	}

	a.strikes++
	block := loginBlockBase << (a.strikes - 1)
	if block > loginBlockMax || block <= 0 {
		block = loginBlockMax
	}
	a.blockedUntil = now.Add(block)
	a.failures = nil // the block replaces them; the next window starts after it
	g.prune(now)
	return block
}

// Succeed clears an address's history. A correct password is the strongest
// evidence there is that this is not the attacker.
func (g *LoginGuard) Succeed(ip string) {
	if ip == "" {
		return
	}
	loginGuard.Lock()
	defer loginGuard.Unlock()
	delete(loginGuard.byIP, ip)
}

// prune drops addresses that are neither blocked nor recently seen, so a wide
// scan cannot grow this map without bound. Called under the lock.
func (g *LoginGuard) prune(now time.Time) {
	for ip, a := range loginGuard.byIP {
		if now.Before(a.blockedUntil) || len(a.failures) > 0 {
			continue
		}
		delete(loginGuard.byIP, ip)
	}
}

// BlockedAddresses lists the addresses currently shut out, for the UI.
func (g *LoginGuard) BlockedAddresses() map[string]time.Duration {
	loginGuard.Lock()
	defer loginGuard.Unlock()
	out := map[string]time.Duration{}
	for ip, a := range loginGuard.byIP {
		if left := time.Until(a.blockedUntil); left > 0 {
			out[ip] = left
		}
	}
	return out
}
