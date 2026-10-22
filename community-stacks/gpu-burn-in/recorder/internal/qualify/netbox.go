package qualify

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// The NetBox import annotates each Machine it creates with its device's web URL.
const netboxDeviceURLAnnotation = "netbox.vcluster.com/url"

var deviceURL = regexp.MustCompile(`^(https?://.+?)/dcim/devices/(\d+)/?$`)

// netboxDevice resolves a device web URL, https://netbox/dcim/devices/10/, to its API base and id.
func netboxDevice(webURL string) (apiBase string, id int, err error) {
	m := deviceURL.FindStringSubmatch(strings.TrimSpace(webURL))
	if m == nil {
		return "", 0, fmt.Errorf("not a NetBox device URL: %q", webURL)
	}
	if _, err := url.Parse(m[1]); err != nil {
		return "", 0, err
	}
	fmt.Sscan(m[2], &id)
	return m[1] + "/api", id, nil
}

// NetBox updates a device's status, tags and journal.
type NetBox struct {
	Token string
	HTTP  *http.Client
}

func (n *NetBox) do(ctx context.Context, method, endpoint string, body, out any) error {
	var r io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		r = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, endpoint, r)
	if err != nil {
		return err
	}
	// NetBox 4.5 v2 tokens (nbt_...) use Bearer; v1 tokens use Token.
	scheme := "Token"
	if strings.HasPrefix(n.Token, "nbt_") {
		scheme = "Bearer"
	}
	req.Header.Set("Authorization", scheme+" "+n.Token)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/json")
	client := n.HTTP
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return fmt.Errorf("%s %s: %s: %s", method, endpoint, resp.Status, strings.TrimSpace(string(b)))
	}
	if out != nil {
		return json.NewDecoder(resp.Body).Decode(out)
	}
	return nil
}

// Record applies a result to a device. On a failure it sets status failed and drops admitTag, the
// tag that brings the device into vCluster Platform. On a pass it adds qualifiedTag. Either way it
// adds a journal entry. Empty tags are left alone.
func (n *NetBox) Record(ctx context.Context, webURL string, r Report, admitTag, qualifiedTag string) error {
	api, id, err := netboxDevice(webURL)
	if err != nil {
		return err
	}
	device := fmt.Sprintf("%s/dcim/devices/%d/", api, id)
	var current struct {
		Tags []struct {
			Slug string `json:"slug"`
		} `json:"tags"`
	}
	if err := n.do(ctx, http.MethodGet, device, nil, &current); err != nil {
		return err
	}
	var tags []map[string]string
	have := map[string]bool{}
	for _, t := range current.Tags {
		if r.Result == "failed" && t.Slug == admitTag && admitTag != "" {
			continue
		}
		have[t.Slug] = true
		tags = append(tags, map[string]string{"slug": t.Slug})
	}
	if r.Result == "passed" && qualifiedTag != "" && !have[qualifiedTag] {
		tags = append(tags, map[string]string{"slug": qualifiedTag})
	}
	if tags == nil {
		tags = []map[string]string{}
	}
	patch := map[string]any{"tags": tags}
	kind := "success"
	if r.Result == "failed" {
		patch["status"] = "failed"
		kind = "danger"
	}
	if err := n.do(ctx, http.MethodPatch, device, patch, nil); err != nil {
		return err
	}
	text := fmt.Sprintf("GPU qualification %s (%s)", r.Result, r.Profile)
	if r.FailedTests != "" {
		text += ": " + r.FailedTests
	}
	text += ". " + r.Summary
	if r.ReportURI != "" {
		text += " Report: " + r.ReportURI
	}
	return n.do(ctx, http.MethodPost, api+"/extras/journal-entries/", map[string]any{
		"assigned_object_type": "dcim.device",
		"assigned_object_id":   id,
		"kind":                 kind,
		"comments":             text,
	}, nil)
}
