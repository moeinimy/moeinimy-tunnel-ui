package config

import "testing"

func TestBrandRoundTrip(t *testing.T) {
	if got := GetBrand(); got != defaultBrand {
		t.Fatalf("fresh: got %q want %q", got, defaultBrand)
	}
	if err := SetBrand("My Panel"); err != nil {
		t.Fatal(err)
	}
	if got := GetBrand(); got != "My Panel" {
		t.Fatalf("after set: got %q", got)
	}
	if err := SetBrand(""); err != nil {
		t.Fatal(err)
	}
	if got := GetBrand(); got != defaultBrand {
		t.Fatalf("after reset: got %q want %q", got, defaultBrand)
	}
	t.Setenv("PANEL_BRAND", "From Env")
	if got := GetBrand(); got != "From Env" {
		t.Fatalf("env override: got %q", got)
	}
}
