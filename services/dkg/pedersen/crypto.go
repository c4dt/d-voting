package pedersen

import (
	"go.dedis.ch/kyber/v3"
	"go.dedis.ch/kyber/v3/util/random"
	"golang.org/x/xerrors"
)

// encryptShim adapts dela's Encrypt (which returns K and a slice of ciphertext
// points Cs) to d-voting's Encrypt (which returns a single ciphertext point C
// and a plaintext remainder).
//
// dela can encrypt an entire message into multiple points. d-voting callers
// expect at most one embedded chunk plus a plaintext remainder, so we split the
// message before calling dela and require exactly one ciphertext point.
func encryptShim(encrypt func([]byte) (kyber.Point, []kyber.Point, error),
	message []byte) (K, C kyber.Point, remainder []byte, err error) {

	max := suite.Point().EmbedLen()
	head := message
	if len(head) > max {
		head = message[:max]
		remainder = append([]byte(nil), message[max:]...)
	}

	K, Cs, err := encrypt(head)
	if err != nil {
		return nil, nil, nil, xerrors.Errorf("failed to encrypt: %v", err)
	}

	if len(Cs) != 1 {
		return nil, nil, nil, xerrors.Errorf("expected exactly one ciphertext point, got %d", len(Cs))
	}

	return K, Cs[0], remainder, nil
}

// randomScalar returns a fresh random scalar from the suite.
func randomScalar() kyber.Scalar {
	return suite.Scalar().Pick(random.New())
}
