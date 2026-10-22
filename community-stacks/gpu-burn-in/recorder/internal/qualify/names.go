package qualify

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
)

// safeConcatName joins parts with "-" the way vCluster Platform names generated objects: a name
// over 63 characters is cut to 55 and suffixed with 7 hex characters of its SHA-256.
// Mirrors loft-enterprise pkg/util/encoding.SafeConcatNameMax.
func safeConcatName(parts ...string) string {
	const max = 63
	full := strings.Join(parts, "-")
	if len(full) <= max {
		return full
	}
	digest := sha256.Sum256([]byte(full))
	return full[:max-8] + "-" + hex.EncodeToString(digest[:])[:7]
}

// outputsSecretName is the Secret, in the StackInstance's namespace, where the Platform keeps the
// instance's captured task outputs as "<task>.<output>" keys.
func outputsSecretName(stackInstance string) string {
	return safeConcatName("stack-outputs", stackInstance)
}
