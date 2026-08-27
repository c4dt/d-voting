package pedersen

import (
	"encoding/json"
	"sync"

	"go.dedis.ch/dela/mino"
	"go.dedis.ch/dela/mino/minogrpc/session"
	"go.dedis.ch/kyber/v3"
)

// state is a struct contained in a handler that allows an actor to read the
// state of that handler. The actor should only use the getter functions to read
// the attributes.
type state struct {
	sync.Mutex
	distKey      kyber.Point
	participants []mino.Address
}

func (s *state) Done() bool {
	s.Lock()
	defer s.Unlock()
	return s.distKey != nil && s.participants != nil
}

func (s *state) GetDistKey() kyber.Point {
	s.Lock()
	defer s.Unlock()
	return s.distKey
}

func (s *state) SetDistKey(key kyber.Point) {
	s.Lock()
	defer s.Unlock()
	s.distKey = key
}

func (s *state) GetParticipants() []mino.Address {
	s.Lock()
	defer s.Unlock()
	return s.participants
}

func (s *state) SetParticipants(addrs []mino.Address) {
	s.Lock()
	defer s.Unlock()
	s.participants = addrs
}

func (s *state) MarshalJSON() ([]byte, error) {
	s.Lock()
	defer s.Unlock()

	var distKeyBuf []byte
	var participantsBuf [][]byte
	var err error

	if s.distKey != nil {
		distKeyBuf, err = s.distKey.MarshalBinary()
		if err != nil {
			return nil, err
		}

		participantsBuf = make([][]byte, len(s.participants))
		for i, p := range s.participants {
			pBuf, err := p.MarshalText()
			if err != nil {
				return nil, err
			}
			participantsBuf[i] = pBuf
		}
	}

	ret, err := json.Marshal(&struct {
		DistKey      []byte   `json:",omitempty"`
		Participants [][]byte `json:",omitempty"`
	}{
		DistKey:      distKeyBuf,
		Participants: participantsBuf,
	})

	return ret, err
}

func (s *state) UnmarshalJSON(data []byte) error {
	aux := &struct {
		DistKey      []byte
		Participants [][]byte
	}{}
	err := json.Unmarshal(data, &aux)
	if err != nil {
		return err
	}

	if aux.DistKey != nil {
		distKey := suite.Point()
		err = distKey.UnmarshalBinary(aux.DistKey)
		if err != nil {
			return err
		}
		s.SetDistKey(distKey)
	} else {
		s.SetDistKey(nil)
	}

	if aux.Participants != nil {
		// TODO: use addressFactory here
		f := session.AddressFactory{}
		var participants = make([]mino.Address, len(aux.Participants))
		for i, partStr := range aux.Participants {
			participants[i] = f.FromText(partStr)
		}
		s.SetParticipants(participants)
	} else {
		s.SetParticipants(nil)
	}

	return nil
}
