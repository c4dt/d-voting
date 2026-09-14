package integration

import (
	"io"
	"math/rand"
	"strconv"
	"strings"
	"testing"

	"github.com/c4dt/d-voting/internal/contracts/evoting"
	"github.com/c4dt/d-voting/internal/contracts/evoting/types"
	"github.com/c4dt/d-voting/internal/core/execution/native"
	"github.com/c4dt/d-voting/internal/core/txn"
	"github.com/c4dt/d-voting/internal/services/dkg"
	"github.com/stretchr/testify/require"
	"go.dedis.ch/kyber/v3"
	"golang.org/x/xerrors"
)

const addAndWaitErr = "failed to addAndWait: %v"

// ballotIsNull checks if a ballot is empty i.e. if all his fields are empty
func ballotIsNull(ballot types.Ballot) bool {
	return ballot.SelectResultIDs == nil && ballot.SelectResult == nil &&
		ballot.RankResultIDs == nil && ballot.RankResult == nil &&
		ballot.TextResultIDs == nil && ballot.TextResult == nil
}

// castVotesRandomly chooses numberOfVotes predefined ballots randomly
// and cast them
func castVotesRandomly(m txManager, actor dkg.Actor, form types.Form,
	numberOfVotes int, ownerID string) ([]types.Ballot, error) {

	possibleBallots := []string{
		string("select:" + encodeID("bb") + ":0,0,1,0\n" +
			"text:" + encodeID("ee") + ":eWVz\n\n"), //encoding of "yes"
		string("select:" + encodeID("bb") + ":1,1,0,0\n" +
			"text:" + encodeID("ee") + ":amE=\n\n"), //encoding of "ja
		string("select:" + encodeID("bb") + ":0,0,0,1\n" +
			"text:" + encodeID("ee") + ":b3Vp\n\n"), //encoding of "oui"
	}

	votes := make([]types.Ballot, numberOfVotes)

	for i := 0; i < numberOfVotes; i++ {
		voterID := strconv.Itoa(i+1) + "11111"
		voterID = voterID[:6]
		addVoter := types.AddVoter{
			FormID:           form.FormID,
			TargetUserID:     voterID,
			PerformingUserID: ownerID,
		}

		data, err := addVoter.Serialize(serdecontext)
		if err != nil {
			return nil, xerrors.Errorf("failed to serialize add voter: %v", err)
		}

		args := []txn.Arg{
			{Key: native.ContractArg, Value: []byte(evoting.ContractName)},
			{Key: evoting.FormArg, Value: data},
			{Key: evoting.CmdArg, Value: []byte(evoting.CmdAddVoterForm)},
		}

		_, err = m.addAndWait(args...)
		if err != nil {
			return nil, xerrors.Errorf(addAndWaitErr, err)
		}
	}

	for i := 0; i < numberOfVotes; i++ {
		randomIndex := rand.Intn(len(possibleBallots))
		vote := possibleBallots[randomIndex]

		ciphervote, err := marshallBallot(strings.NewReader(vote), actor, form.ChunksPerBallot())
		if err != nil {
			return nil, xerrors.Errorf("failed to marshallBallot: %v", err)
		}

		/*
				For the voters permission verification, we need a voter id. As this method
				does not use a fix number of voters, we need a way to generate these voters'
				id.	We decided to use the ith voter as an id.
				As the sciper range from 100000 to 999999 and as we don't know how many
				voters they will be created in the method, we pad the ith number with
			 	1's, and then we truncate to take the first six number.

				example run
				if it generates 10 voters, i is going to vary from 0 to 9
				with the +1
				from 1 to 10
				we are going to get id:
				1 11111
				2 11111
				3 11111
				4 11111
				5 11111
				6 11111
				7 11111
				8 11111
				9 11111
				10 11111 -> truncate to 6 digits: 101111
		*/
		voterID := strconv.Itoa(i+1) + "11111"
		voterID = voterID[:6]

		castVote := types.CastVote{
			FormID:  form.FormID,
			VoterID: voterID,
			Ballot:  ciphervote,
		}

		data, err := castVote.Serialize(serdecontext)
		if err != nil {
			return nil, xerrors.Errorf("failed to serialize cast vote: %v", err)
		}

		args := []txn.Arg{
			{Key: native.ContractArg, Value: []byte(evoting.ContractName)},
			{Key: evoting.FormArg, Value: data},
			{Key: evoting.CmdArg, Value: []byte(evoting.CmdCastVote)},
		}

		_, err = m.addAndWait(args...)
		if err != nil {
			return nil, xerrors.Errorf(addAndWaitErr, err)
		}

		var ballot types.Ballot
		err = ballot.Unmarshal(vote, form)
		if err != nil {
			return nil, xerrors.Errorf("failed to unmarshal ballot: %v", err)
		}

		votes[i] = ballot
	}

	return votes, nil
}

// castBadVote casts a vote with the good format but invalid content
func castBadVote(m txManager, actor dkg.Actor, form types.Form, numberOfBadVotes int) error {

	possibleBallots := []string{
		string("select:" + encodeID("bb") + ":1,0,1,1\n" +
			"text:" + encodeID("ee") + ":bm9ub25vbm8=\n\n"), //encoding of "nononono"
		string("select:" + encodeID("bb") + ":1,1,1,1\n" +
			"text:" + encodeID("ee") + ":bm8=\n\n"), //encoding of "no"

	}

	for i := 0; i < numberOfBadVotes; i++ {
		randomIndex := rand.Intn(len(possibleBallots))
		vote := possibleBallots[randomIndex]

		ciphervote, err := marshallBallot(strings.NewReader(vote), actor, form.ChunksPerBallot())
		if err != nil {
			return xerrors.Errorf("failed to marshallBallot: %v", err)
		}

		voterID := "badUser " + strconv.Itoa(i)

		castVote := types.CastVote{
			FormID:  form.FormID,
			VoterID: voterID,
			Ballot:  ciphervote,
		}

		data, err := castVote.Serialize(serdecontext)
		if err != nil {
			return xerrors.Errorf("failed to serialize cast vote: %v", err)
		}

		args := []txn.Arg{
			{Key: native.ContractArg, Value: []byte(evoting.ContractName)},
			{Key: evoting.FormArg, Value: data},
			{Key: evoting.CmdArg, Value: []byte(evoting.CmdCastVote)},
		}

		_, err = m.addAndWait(args...)
		if err != nil {
			return xerrors.Errorf(addAndWaitErr, err)
		}
	}

	return nil
}

// marshallBallot marshals a ballot and encrypts it
func marshallBallot(vote io.Reader, actor dkg.Actor, chunks int) (types.Ciphervote, error) {

	var ballot = make([]types.EGPair, chunks)

	buf := make([]byte, 29)

	for i := 0; i < chunks; i++ {
		var K, C kyber.Point
		var err error

		n, err := vote.Read(buf)
		if err != nil {
			return nil, xerrors.Errorf("failed to read: %v", err)
		}

		K, C, _, err = actor.Encrypt(buf[:n])
		if err != nil {
			return types.Ciphervote{}, xerrors.Errorf("failed to encrypt the plaintext: %v", err)
		}

		pair := types.EGPair{
			K: K,
			C: C,
		}

		ballot[i] = pair

	}

	return ballot, nil
}

func decryptBallots(m txManager, actor dkg.Actor, form types.Form, userID string) error {
	if form.Status != types.PubSharesSubmitted {
		return xerrors.Errorf("cannot decrypt: not all pubShares submitted")
	}

	decryptBallots := types.CombineShares{
		FormID: form.FormID,
		UserID: userID,
	}

	data, err := decryptBallots.Serialize(serdecontext)
	if err != nil {
		return xerrors.Errorf("failed to serialize ballots: %v", err)
	}

	args := []txn.Arg{
		{Key: native.ContractArg, Value: []byte(evoting.ContractName)},
		{Key: evoting.FormArg, Value: data},
		{Key: evoting.CmdArg, Value: []byte(evoting.CmdCombineShares)},
	}

	_, err = m.addAndWait(args...)
	if err != nil {
		return xerrors.Errorf(addAndWaitErr, err)
	}

	return nil
}

// checkBallots checks that the decrypted ballots are correct
// and match the casted votes
func checkBallots(decryptedBallots, castedVotes []types.Ballot, t *testing.T) {
	require.Len(t, decryptedBallots, len(castedVotes))

	for _, b := range decryptedBallots {
		ok := false
		for i, casted := range castedVotes {
			if b.Equal(casted) {
				ok = true
				// remove the casted vote from the list
				castedVotes = append(castedVotes[:i], castedVotes[i+1:]...)
				break
			}
		}
		require.True(t, ok)
	}
	require.Empty(t, castedVotes)

}
