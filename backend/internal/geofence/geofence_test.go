package geofence

import "testing"

func TestContainsLatLng(t *testing.T) {
	cases := []struct {
		name string
		lat  float64
		lng  float64
		want bool
	}{
		{"the Loop downtown", 41.8781, -87.6298, true},
		{"Wrigley Field", 41.9484, -87.6553, true},
		{"Hyde Park", 41.7943, -87.5907, true},
		{"O'Hare panhandle", 41.9742, -87.9073, true},
		{"lakefront drift ~75m offshore (buffer keeps it)", 41.90415, -87.62269, true},
		{"Lake Michigan far offshore", 41.8800, -87.5800, false},
		{"Evanston suburb (north)", 42.0451, -87.6877, false},
		{"Oak Park suburb (west)", 41.8850, -87.7845, false},
		{"Naperville far west", 41.7508, -88.1535, false},
		{"Indiana", 41.6000, -87.3000, false},
	}
	for _, c := range cases {
		if got := ContainsLatLng(c.lat, c.lng); got != c.want {
			t.Errorf("%s: ContainsLatLng(%v, %v) = %v, want %v", c.name, c.lat, c.lng, got, c.want)
		}
	}
}
