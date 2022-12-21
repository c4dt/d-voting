import React, { FC, useEffect, useState } from 'react';
import { Answers, Configuration, ID, RANK, SELECT, SUBJECT, TEXT } from 'types/configuration';
import * as types from 'types/configuration';
import Rank, { handleOnDragEnd } from './Rank';
import Select from './Select';
import Text from './Text';
import { DragDropContext } from 'react-beautiful-dnd';

type BallotDisplayProps = {
  configuration: Configuration;
  answers: Answers;
  setAnswers: (answers: Answers) => void;
  userErrors: string;
  language: string;
};

const BallotDisplay: FC<BallotDisplayProps> = ({
  configuration,
  answers,
  setAnswers,
  userErrors,
  language,
}) => {
  const [titles, setTitles] = useState<any>({});
  useEffect(() => {
    try {
      const ts = JSON.parse(configuration.MainTitle);
      setTitles(ts);
    } catch (e) {
      console.log('error', e);
    }
  }, [configuration]);

  const SubjectElementDisplay = (element: types.SubjectElement) => {
    return (
      <div className="pl-4 sm:pl-6">
        {element.Type === RANK && (
          <Rank rank={element as types.RankQuestion} answers={answers} language={language} />
        )}
        {element.Type === SELECT && (
          <Select
            select={element as types.SelectQuestion}
            answers={answers}
            setAnswers={setAnswers}
            language={language}
          />
        )}
        {element.Type === TEXT && (
          <Text
            text={element as types.TextQuestion}
            answers={answers}
            setAnswers={setAnswers}
            language={language}
          />
        )}
      </div>
    );
  };

  const SubjectTree = (subject: types.Subject) => {
    return (
      <div key={subject.ID}>
        <h3 className="text-xl break-all pt-1 pb-1 sm:pt-2 sm:pb-2 border-t font-bold text-gray-600">
          {language === 'en' && subject.Title}
          {language === 'fr' && subject.TitleFr}
          {language === 'de' && subject.TitleDe}
        </h3>
        {subject.Order.map((id: ID) => (
          <div key={id}>
            {subject.Elements.get(id).Type === SUBJECT ? (
              <div className="pl-4 sm:pl-6">
                {SubjectTree(subject.Elements.get(id) as types.Subject)}
              </div>
            ) : (
              SubjectElementDisplay(subject.Elements.get(id))
            )}
          </div>
        ))}
      </div>
    );
  };

  return (
    <DragDropContext onDragEnd={(dropRes) => handleOnDragEnd(dropRes, answers, setAnswers)}>
      <div className="w-full mb-0 sm:mb-4 mt-4 sm:mt-6">
        <h3 className="pb-6 break-all text-2xl text-center text-gray-700">
          {language === 'en' && titles.en}
          {language === 'fr' && titles.fr}
          {language === 'de' && titles.de}
        </h3>
        <div className="flex flex-col">
          {configuration.Scaffold.map((subject: types.Subject) => SubjectTree(subject))}
          <div className="text-red-600 text-sm pt-3 pb-1">{userErrors}</div>
        </div>
      </div>
    </DragDropContext>
  );
};

export default BallotDisplay;
