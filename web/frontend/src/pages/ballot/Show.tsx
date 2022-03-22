import React, { FC, useEffect, useState } from 'react';
import { CloudUploadIcon } from '@heroicons/react/outline';
import { useTranslation } from 'react-i18next';
import { Link, useParams } from 'react-router-dom';
import kyber from '@dedis/kyber';
import PropTypes from 'prop-types';
import { Buffer } from 'buffer';
import { DragDropContext, Droppable } from 'react-beautiful-dnd';

import { ROUTE_BALLOT_INDEX } from '../../Routes';
import useElection from 'components/utils/useElection';
import usePostCall from 'components/utils/usePostCall';
import { ENDPOINT_EVOTING_CAST_BALLOT } from 'components/utils/Endpoints';
import Modal from 'components/modal/Modal';
import { OPEN } from 'components/utils/StatusNumber';
import { encryptVote } from './components/VoteEncrypt';
import useConfiguration, {
  Question,
  RANK,
  ROOT_ID,
  SELECT,
  SUBJECT,
  TEXT,
} from 'components/utils/useConfiguration';
import { ballotIsValid } from './HandleAnswers';
import { selectDisplay, selectHintDisplay } from './ShowSelects';
import { handleOnDragEnd, rankDisplay } from './ShowRanks';
import { textDisplay, textHintDisplay } from './ShowTexts';
import { ID } from 'components/utils/types';

const Ballot: FC = () => {
  const { t } = useTranslation();
  const { electionId } = useParams();
  const token = sessionStorage.getItem('token');
  const { loading, configuration, electionID, status, pubKey } = useElection(electionId, token);
  const {
    sortedQuestions,
    selectStates,
    setSelectStates,
    rankStates,
    setRankStates,
    textStates,
    setTextStates,
    answerErrors,
    setAnswerErrors,
  } = useConfiguration(configuration);
  const [userErrors, setUserErrors] = useState('');
  const edCurve = kyber.curve.newCurve('edwards25519');
  const [postRequest, setPostRequest] = useState(null);
  const [postError, setPostError] = useState('');
  const { postData } = usePostCall(setPostError);
  const [showModal, setShowModal] = useState(false);
  const [modalText, setModalText] = useState(t('voteSuccess') as string);

  useEffect(() => {
    if (postRequest !== null) {
      setPostError(null);
      postData(ENDPOINT_EVOTING_CAST_BALLOT, postRequest, setShowModal);
      setPostRequest(null);
    }
  }, [postData, postRequest]);

  useEffect(() => {
    if (postError !== null) {
      if (postError.includes('ECONNREFUSED')) {
        setModalText(t('errorServerDown'));
      } else {
        setModalText(t('voteFailure'));
      }
    } else {
      setModalText(t('voteSuccess'));
    }
  }, [postError, t]);

  const hexToBytes = (hex: string) => {
    let bytes: number[] = [];
    for (let c = 0; c < hex.length; c += 2) {
      bytes.push(parseInt(hex.substr(c, 2), 16));
    }
    return new Uint8Array(bytes);
  };

  const createBallot = (K: Buffer, C: Buffer) => {
    let vote = JSON.stringify({ K: Array.from(K), C: Array.from(C) });
    return {
      ElectionID: electionID,
      UserId: sessionStorage.getItem('id'),
      Ballot: Buffer.from(vote),
      Token: token,
    };
  };

  const sendBallot = async () => {
    // TODO: encode ballot: encodeBallot(selectStates, rankStates, textStates);
    let encodedAnswers = ['deadbeef'];
    const [K, C] = encryptVote(encodedAnswers, Buffer.from(hexToBytes(pubKey).buffer), edCurve);
    //sending the ballot to evoting server
    let ballot = createBallot(K, C);
    let newRequest = {
      method: 'POST',
      body: JSON.stringify(ballot),
    };
    setPostRequest(newRequest);
  };

  const handleClick = () => {
    if (ballotIsValid(sortedQuestions, selectStates, textStates, answerErrors, setAnswerErrors)) {
      setUserErrors('');
      sendBallot();
    } else {
      setUserErrors(t('incompleteBallot'));
    }
  };

  const subjectTree = (sorted: Question[], parentId: ID) => {
    const questions = sorted.filter((question) => question.ParentID === parentId);
    if (!questions.length) {
      return null;
    }
    return (
      <div>
        {questions.map((question) => (
          <div className="pl-6">
            <h3 className="text-lg text-gray-600">{question.Content.Title}</h3>
            <div>
              {question.Type === SELECT ? (
                <div>
                  {selectHintDisplay(question)}
                  <div className="pl-8">
                    {Array.from(
                      selectStates.find((s) => s.ID === question.Content.ID).Answers.entries()
                    ).map(([choiceIndex, isChecked]) =>
                      selectDisplay(
                        isChecked,
                        question.Content.Choices[choiceIndex],
                        question.Content,
                        selectStates,
                        setSelectStates,
                        answerErrors,
                        setAnswerErrors
                      )
                    )}
                  </div>
                </div>
              ) : question.Type === RANK ? (
                <div className="mt-5 pl-8">
                  <Droppable droppableId={String(question.Content.ID)}>
                    {(provided) => (
                      <ul
                        className={question.Content.ID}
                        {...provided.droppableProps}
                        ref={provided.innerRef}>
                        {Array.from(
                          rankStates.find((s) => s.ID === question.Content.ID).Answers.entries()
                        ).map(([rankIndex, choiceIndex]) =>
                          rankDisplay(
                            rankIndex,
                            question.Content.Choices[choiceIndex],
                            question.Content,
                            rankStates,
                            setRankStates,
                            answerErrors,
                            setAnswerErrors
                          )
                        )}
                        {provided.placeholder}
                      </ul>
                    )}
                  </Droppable>
                </div>
              ) : question.Type === TEXT ? (
                <div>
                  {textHintDisplay(question)}
                  <div className="pl-8">
                    {question.Content.Choices.map((choice) =>
                      textDisplay(
                        choice,
                        question.Content,
                        textStates,
                        setTextStates,
                        answerErrors,
                        setAnswerErrors
                      )
                    )}
                  </div>
                </div>
              ) : null}
            </div>
            <div>
              {question.Type === SUBJECT ? (
                subjectTree(sorted, question.Content.ID)
              ) : (
                <div className="text-red-600 text-sm py-2 pl-2">
                  {answerErrors.find((e) => e.ID === question.Content.ID).Message}
                </div>
              )}
            </div>
          </div>
        ))}
      </div>
    );

    /*return (
      <div>
        {questions.map((question) => (
          <div className="pl-6">
            <h3 className="text-lg text-gray-600">{question.Content.Title}</h3>
            <div className="pl-8">
              {question.Type === SELECT ? (
                <div>
                  {selectHintDisplay(question)}
                  {Array.from(
                    selectStates.find((s) => s.ID === question.Content.ID).Answers.entries()
                  ).map(([choiceIndex, isChecked]) =>
                    selectDisplay(
                      isChecked,
                      question.Content.Choices[choiceIndex],
                      question.Content,
                      selectStates,
                      setSelectStates,
                      answerErrors,
                      setAnswerErrors
                    )
                  )}
                </div>
              ) : question.Type === RANK ? (
                <div className="mt-5">
                  <Droppable droppableId={String(question.Content.ID)}>
                    {(provided) => (
                      <ul
                        className={question.Content.ID}
                        {...provided.droppableProps}
                        ref={provided.innerRef}>
                        {Array.from(
                          rankStates.find((s) => s.ID === question.Content.ID).Answers.entries()
                        ).map(([rankIndex, choiceIndex]) =>
                          rankDisplay(
                            rankIndex,
                            question.Content.Choices[choiceIndex],
                            question.Content,
                            rankStates,
                            setRankStates,
                            answerErrors,
                            setAnswerErrors
                          )
                        )}
                        {provided.placeholder}
                      </ul>
                    )}
                  </Droppable>
                </div>
              ) : question.Type === TEXT ? (
                <div>
                  {textHintDisplay(question)}
                  {question.Content.Choices.map((choice) =>
                    textDisplay(
                      choice,
                      question.Content,
                      textStates,
                      setTextStates,
                      answerErrors,
                      setAnswerErrors
                    )
                  )}
                </div>
              ) : null}
            </div>
            <div>
              {question.Type === SUBJECT ? (
                subjectTree(sorted, question.Content.ID)
              ) : (
                <div className="text-red-600 text-sm py-2 pl-2">
                  {answerErrors.find((e) => e.ID === question.Content.ID).Message}
                </div>
              )}
            </div>
          </div>
        ))}
      </div>
    );*/
  };

  const ballotDisplay = () => {
    return (
      <DragDropContext
        onDragEnd={(e) =>
          handleOnDragEnd(e, rankStates, setRankStates, answerErrors, setAnswerErrors)
        }>
        <div>
          <h3 className="font-bold uppercase pt-4 pb-8 text-2xl text-center text-gray-600">
            {configuration.MainTitle}
          </h3>
          <div>{subjectTree(sortedQuestions, ROOT_ID)}</div>
          <div>
            <div className="text-red-600 text-sm py-2 pl-2">{userErrors}</div>
            <div className="flex">
              <button
                type="button"
                className="flex inline-flex mt-2 mb-2 ml-2 items-center px-4 py-2 border border-transparent rounded-md shadow-sm text-sm font-medium text-white bg-indigo-500 hover:bg-indigo-600"
                onClick={handleClick}>
                <CloudUploadIcon className="-ml-1 mr-2 h-5 w-5" aria-hidden="true" />
                {t('castVote')}
              </button>
            </div>
          </div>
        </div>
      </DragDropContext>
    );
  };

  const electionClosedDisplay = () => {
    return (
      <div>
        <div> {t('voteImpossible')}</div>
        <Link to={ROUTE_BALLOT_INDEX}>
          <button
            type="button"
            className="flex inline-flex mt-2 mb-2 ml-2 items-center px-4 py-2 border border-transparent rounded-md shadow-sm text-sm font-medium text-white bg-indigo-500 hover:bg-indigo-600">
            {t('back')}
          </button>
        </Link>
      </div>
    );
  };

  return (
    <div className="mx-4 my-4 px-8 py-4 shadow-lg rounded-md">
      <Modal
        showModal={showModal}
        setShowModal={setShowModal}
        textModal={modalText}
        buttonRightText={t('close')}
      />
      {loading ? (
        <p className="loading">{t('loading')}</p>
      ) : (
        <div>{status === OPEN ? ballotDisplay() : electionClosedDisplay()}</div>
      )}
    </div>
  );
};

Ballot.propTypes = {
  location: PropTypes.any,
};

export default Ballot;
