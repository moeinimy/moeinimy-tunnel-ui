package locale

import (
	"strings"
	"testing"

	"github.com/nicksnyder/go-i18n/v2/i18n"
)

// Locale strings carry "{{ .Brand }}" rather than a baked-in product name, and
// createTemplateData supplies it on every lookup — so translated copy follows the
// operator's rename (config.GetBrand) the same way the templates do. Before this,
// "Support VPN-UI" stayed VPN-UI in all 13 locales no matter what the panel was
// called.
func TestBrandIsInterpolatedIntoTranslations(t *testing.T) {
	t.Setenv("PANEL_BRAND", "Moeinimy-UI")

	b := buildBundle(t)
	i18nBundle = b
	localizerDefault = i18n.NewLocalizer(b, "en-US")
	LocalizerWeb = i18n.NewLocalizer(b, "en-US")

	got := I18n(Web, "pages.index.donateTitle")
	if !strings.Contains(got, "Moeinimy-UI") {
		t.Errorf("donateTitle = %q, want it to carry the configured brand", got)
	}
	if strings.Contains(got, "VPN-UI") {
		t.Errorf("donateTitle still carries a hardcoded product name: %q", got)
	}
	if strings.Contains(got, "{{") {
		t.Errorf("donateTitle left the placeholder unexpanded: %q", got)
	}
}

// A caller-supplied param of the same name must still win, so an explicit value
// is never silently replaced by the global default.
func TestExplicitBrandParamOverridesTheDefault(t *testing.T) {
	t.Setenv("PANEL_BRAND", "Moeinimy-UI")

	if data := createTemplateData([]string{"Brand==Explicit"}); data["Brand"] != "Explicit" {
		t.Errorf("Brand = %v, want the caller's value to take precedence", data["Brand"])
	}
	if data := createTemplateData(nil); data["Brand"] != "Moeinimy-UI" {
		t.Errorf("Brand = %v, want the configured brand when no param is given", data["Brand"])
	}
}
