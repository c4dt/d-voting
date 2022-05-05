import React, { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import ConfirmModal from '../modal/ConfirmModal';
import usePostCall from './usePostCall';
import * as endpoints from './Endpoints';
import { ID } from 'types/configuration';
import { ACTION, STATUS } from 'types/election';
import {
  CancelButton,
  CloseButton,
  DecryptButton,
  InitializeButton,
  OpenButton,
  ResultButton,
  SetupButton,
  ShuffleButton,
} from './ActionButtons';
import { poll } from './usePolling';
import AddProxyAddressesModal from 'components/modal/AddProxyAddressesModal';

const useChangeAction = (
  status: STATUS,
  electionID: ID,
  roster: string[],
  setStatus: (status: STATUS) => void,
  setResultAvailable: ((available: boolean) => void | null) | undefined,
  setTextModalError: (value: ((prevState: null) => '') | string) => void,
  setShowModalError: (willShow: boolean) => void,
  setGetError: (error: string) => void
) => {
  const { t } = useTranslation();
  const [isInitialized, setIsInitialized] = useState(false);
  const [initializedNodes, setInitializedNodes] = useState<Map<string, boolean>>();
  const [isSettingUp, setIsSettingUp] = useState(false);
  const [isOpening, setIsOpening] = useState(false);
  const [isClosing, setIsClosing] = useState(false);
  const [isCanceling, setIsCanceling] = useState(false);
  const [isShuffling, setIsShuffling] = useState(false);
  const [isDecrypting, setIsDecrypting] = useState(false);
  const [showModalClose, setShowModalClose] = useState(false);
  const [showModalCancel, setShowModalCancel] = useState(false);
  const [showModalAddProxy, setShowModalAddProxy] = useState(false);
  const [userConfirmedAddProxy, setUserConfirmedAddProx] = useState(false);
  const [userConfirmedClosing, setUserConfirmedClosing] = useState(false);
  const [userConfirmedCanceling, setUserConfirmedCanceling] = useState(false);
  const [proxyAddresses, setProxyAddresses] = useState<Map<string, string>>();

  const modalClose = (
    <ConfirmModal
      showModal={showModalClose}
      setShowModal={setShowModalClose}
      textModal={t('confirmCloseElection')}
      setUserConfirmedAction={setUserConfirmedClosing}
    />
  );
  const modalCancel = (
    <ConfirmModal
      showModal={showModalCancel}
      setShowModal={setShowModalCancel}
      textModal={t('confirmCancelElection')}
      setUserConfirmedAction={setUserConfirmedCanceling}
    />
  );
  const modalAddProxyAddresses = (
    <AddProxyAddressesModal
      roster={roster}
      proxyAddresses={proxyAddresses}
      setProxyAddresses={setProxyAddresses}
      showModal={showModalAddProxy}
      setShowModal={setShowModalAddProxy}
      setUserConfirmedAction={setUserConfirmedAddProx}
    />
  );

  const [postError, setPostError] = useState(t('operationFailure') as string);
  const sendFetchRequest = usePostCall(setPostError);

  const electionUpdate = async (action: string, endpoint: string) => {
    const req = {
      method: 'PUT',
      body: JSON.stringify({
        Action: action,
      }),
      headers: {
        'Content-Type': 'application/json',
      },
    };
    return sendFetchRequest(endpoint, req, setIsClosing);
  };

  const initializeNode = async (address: string) => {
    const request = {
      method: 'POST',
      body: JSON.stringify({
        ElectionID: electionID,
        ProxyAddress: address,
      }),
      headers: {
        'Content-Type': 'application/json',
      },
    };
    return sendFetchRequest(endpoints.dkgActors, request, setIsInitialized);
  };

  // Start to poll on the given endpoint, statusToMatch is the status we are
  // waiting for to stop polling. The previous status is used if there's an error,
  // in which case the election status is set back to this value.
  const pollStatus = (endpoint: string, statusToMatch: STATUS, previousStatus: STATUS, signal) => {
    const interval = 1000;
    const request = {
      method: 'GET',
      signal: signal,
    };

    const onFullFilled = () => {
      if (setGetError !== null && setGetError !== undefined) {
        setGetError(null);
      }

      setStatus(statusToMatch);
    };

    const onRejected = (error) => {
      // AbortController sends an AbortError of type DOMException
      // when the component is unmounted, we ignore those
      if (!(error instanceof DOMException)) {
        if (setGetError !== null && setGetError !== undefined) {
          setGetError(error.message);
        }

        setStatus(previousStatus);
      }
    };

    const match = (s: STATUS) => s === statusToMatch;

    poll(endpoint, request, match, interval)
      .then(onFullFilled, onRejected)
      .catch((e) => {
        setStatus(previousStatus);
        setGetError(e.message);
        setShowModalError(true);
      });
  };

  useEffect(() => {
    // use an abortController to stop polling when the component is unmounted
    const abortController = new AbortController();
    const signal = abortController.signal;

    if (status == STATUS.OnGoingSetup) {
      console.log('polling setup');
      pollStatus(
        endpoints.editDKGActors(electionID),
        STATUS.Setup,
        STATUS.InitializedNodes,
        signal
      );
    }

    if (status == STATUS.OnGoingShuffle) {
      pollStatus(endpoints.election(electionID), STATUS.ShuffledBallots, STATUS.Closed, signal);
    }

    if (status == STATUS.OnGoingDecryption) {
      pollStatus(
        endpoints.editDKGActors(electionID),
        STATUS.DecryptedBallots,
        STATUS.ShuffledBallots,
        signal
      );
    }

    return () => {
      abortController.abort();
    };
  }, [status]);

  useEffect(() => {
    if (postError !== null) {
      setTextModalError(postError);
      setPostError(null);
    }
  }, [postError, setTextModalError]);

  useEffect(() => {
    //check if close button was clicked and the user validated the confirmation window
    if (isClosing && userConfirmedClosing) {
      const close = async () => {
        const closeSuccess = await electionUpdate(
          ACTION.Close,
          endpoints.editElection(electionID.toString())
        );

        if (closeSuccess) {
          setStatus(STATUS.Closed);
        } else {
          setShowModalError(true);
        }
        setUserConfirmedClosing(false);
      };

      close().catch(console.error);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [
    isClosing,
    sendFetchRequest,
    setShowModalError,
    setStatus,
    showModalClose,
    userConfirmedClosing,
  ]);

  useEffect(() => {
    if (isCanceling && userConfirmedCanceling) {
      const cancel = async () => {
        const cancelSuccess = await electionUpdate(
          ACTION.Cancel,
          endpoints.editElection(electionID.toString())
        );

        if (cancelSuccess) {
          setStatus(STATUS.Canceled);
        } else {
          setShowModalError(true);
        }
        setUserConfirmedCanceling(false);
        setPostError(null);
      };

      cancel().catch(console.error);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isCanceling, sendFetchRequest, setShowModalError, setStatus, userConfirmedCanceling]);

  useEffect(() => {
    if (userConfirmedAddProxy) {
      proxyAddresses.forEach(async (address, index) => {
        const initSuccess = await initializeNode(address);

        if (initSuccess && postError === null) {
          const initNodes = new Map(initializedNodes);
          initNodes.set(address, true);
          console.log('iciiii');
          setInitializedNodes(initNodes);
        } else {
          setShowModalError(true);
        }
        setPostError(null);
      });
    }
  }, [userConfirmedAddProxy]);

  useEffect(() => {
    if (initializedNodes) {
      // All the nodes have been initialized
      if (!Array.from(initializedNodes.values()).includes(false)) {
        console.log('changing state');
        setStatus(STATUS.InitializedNodes);
      }
    }
  }, [initializedNodes]);

  const handleInitialize = () => {
    setShowModalAddProxy(true);
  };

  // Setup one of the node and then start polling to know when all the nodes
  // have been setup
  const handleSetup = async () => {
    setIsSettingUp(true);
    const setupSuccess = await electionUpdate(ACTION.Setup, endpoints.editDKGActors(electionID));

    if (setupSuccess && postError === null) {
      setStatus(STATUS.OnGoingSetup);
    } else {
      setShowModalError(true);
      setIsSettingUp(false);
    }
    setPostError(null);
  };

  const handleOpen = async () => {
    const openSuccess = await electionUpdate(ACTION.Open, endpoints.editElection(electionID));

    if (openSuccess && postError === null) {
      setStatus(STATUS.Open);
    } else {
      setShowModalError(true);
      setIsOpening(false);
    }
    setPostError(null);
  };

  const handleClose = () => {
    setShowModalClose(true);
    setIsClosing(true);
  };

  const handleCancel = () => {
    setShowModalCancel(true);
    setIsCanceling(true);
  };

  // Start the shuffle and poll to know when the shuffle has finished
  const handleShuffle = async () => {
    setIsShuffling(true);
    const shuffleSuccess = await electionUpdate(ACTION.Shuffle, endpoints.editShuffle(electionID));

    if (shuffleSuccess && postError === null) {
      setStatus(STATUS.OnGoingShuffle);
    } else {
      setShowModalError(true);
      setIsShuffling(false);
    }
    setPostError(null);
  };

  // Start decrypting the ballots and poll to know when the decryption has finished
  const handleDecrypt = async () => {
    setIsDecrypting(true);
    const decryptSuccess = await electionUpdate(
      ACTION.BeginDecryption,
      endpoints.editDKGActors(electionID)
    );

    if (decryptSuccess && postError === null) {
      setStatus(STATUS.OnGoingDecryption);
    } else {
      setShowModalError(true);
      setIsDecrypting(false);
    }
    setPostError(null);
  };

  useEffect(() => {
    if (status === STATUS.DecryptedBallots) {
      setStatus(STATUS.ResultAvailable);

      setResultAvailable(true);
    }
  }, [status]);

  const getAction = () => {
    switch (status) {
      case STATUS.Initial:
        return (
          <span>
            <InitializeButton status={status} handleInitialize={handleInitialize} />
          </span>
        );
      case STATUS.InitializedNodes:
        return (
          <span>
            <SetupButton status={status} handleSetup={handleSetup} />
          </span>
        );
      case STATUS.OnGoingSetup:
        return <span>{t('statusOnGoingSetup')}</span>;
      case STATUS.Setup:
        return (
          <span>
            <OpenButton status={status} handleOpen={handleOpen} />
          </span>
        );
      case STATUS.Open:
        return (
          <span>
            <CloseButton status={status} handleClose={handleClose} />
            <CancelButton status={status} handleCancel={handleCancel} />
          </span>
        );
      case STATUS.Closed:
        return (
          <span>
            <ShuffleButton
              status={status}
              isShuffling={isShuffling}
              handleShuffle={handleShuffle}
            />
          </span>
        );
      case STATUS.OnGoingShuffle:
        return <span>{t('statusOnGoingShuffle')}</span>;

      case STATUS.ShuffledBallots:
        return (
          <span>
            <DecryptButton
              status={status}
              isDecrypting={isDecrypting}
              handleDecrypt={handleDecrypt}
            />
          </span>
        );
      case STATUS.OnGoingDecryption:
        return <span>{t('statusOnGoingDecryption')}</span>;
      case STATUS.ResultAvailable:
        return (
          <span>
            <ResultButton status={status} electionID={electionID} />
          </span>
        );
      case STATUS.Canceled:
        return <span> --- </span>;
      default:
        return <span> --- </span>;
    }
  };

  return { getAction, modalClose, modalCancel, modalAddProxyAddresses };
};

export default useChangeAction;
