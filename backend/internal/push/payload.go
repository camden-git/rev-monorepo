package push

import "encoding/json"

// Environment selects which APNs host a device token is valid against. A token
// minted under the development aps-environment only works on sandbox, and a
// production token only on the production host, so the client reports which one
// its build used.
type Environment string

const (
	Sandbox    Environment = "sandbox"
	Production Environment = "production"
)

// Payload is the user-facing notification to deliver.
type Payload struct {
	Title    string
	Body     string
	Sound    string
	Badge    *int
	ThreadID string
	Category string
	// Data is merged into the top level of the APNs payload alongside "aps" so
	// the app can route the tap (e.g. {"type": "follow_request", "user_id": ...}).
	Data map[string]any
}

// encode renders the APNs JSON body for this payload.
func (p Payload) encode() ([]byte, error) {
	alert := map[string]any{}
	if p.Title != "" {
		alert["title"] = p.Title
	}
	if p.Body != "" {
		alert["body"] = p.Body
	}

	aps := map[string]any{"alert": alert}
	sound := p.Sound
	if sound == "" {
		sound = "default"
	}
	aps["sound"] = sound
	if p.Badge != nil {
		aps["badge"] = *p.Badge
	}
	if p.ThreadID != "" {
		aps["thread-id"] = p.ThreadID
	}
	if p.Category != "" {
		aps["category"] = p.Category
	}

	root := map[string]any{"aps": aps}
	for k, v := range p.Data {
		if k == "aps" {
			continue // never let custom data clobber the reserved key
		}
		root[k] = v
	}
	return json.Marshal(root)
}
