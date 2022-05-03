import { FlashContext, FlashLevel } from 'index';
import React, { FC, useContext } from 'react';
import { useTranslation } from 'react-i18next';

const Home: FC = () => {
  const { t } = useTranslation();
  const fctx = useContext(FlashContext);

  return (
    <div className="flex flex-col">
      <h1>{t('homeTitle')}</h1>
      <div>{t('homeText')}</div>
      <div className="flex">
        <button
          className="inline-flex my-2 ml-2 items-center px-4 py-2 border border-transparent rounded-md shadow-sm text-sm font-medium text-white bg-indigo-500 hover:bg-indigo-600"
          onClick={() => {
            fctx.addMessage(
              'Hello world! Hello world! Hello world! Hello world! Hello world! Hello world! Hello world! Hello world! Hello world! Hello world! Hello world! Hello world! Hello world!',
              FlashLevel.Info
            );
          }}>
          Add flash info
        </button>
        <button
          className="inline-flex my-2 ml-2 items-center px-4 py-2 border border-transparent rounded-md shadow-sm text-sm font-medium text-white bg-indigo-500 hover:bg-indigo-600"
          onClick={() => {
            fctx.addMessage('Hello world!', FlashLevel.Warning);
          }}>
          Add flash warning
        </button>
        <button
          className="inline-flex my-2 ml-2 items-center px-4 py-2 border border-transparent rounded-md shadow-sm text-sm font-medium text-white bg-indigo-500 hover:bg-indigo-600"
          onClick={() => {
            fctx.addMessage('Hello world!', FlashLevel.Error);
          }}>
          Add flash error
        </button>
      </div>
    </div>
  );
};

export default Home;
