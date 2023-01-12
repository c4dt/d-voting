import React, { FC, useEffect, useState } from 'react';
import { LightFormInfo } from 'types/form';
import { Link } from 'react-router-dom';
import FormStatus from './FormStatus';
import QuickAction from './QuickAction';
import { default as i18n } from 'i18next';

type FormRowProps = {
  form: LightFormInfo;
};

const FormRow: FC<FormRowProps> = ({ form }) => {
  const [titles, setTitles] = useState<any>({});
  useEffect(() => {
    if (form.Title === '') return;
    const ts = JSON.parse(form.Title);
    setTitles(ts);
  }, [form]);
  return (
    <tr className="bg-white border-b hover:bg-gray-50 ">
      <td className="px-1.5 sm:px-6 py-4 font-medium text-gray-900 whitespace-nowrap truncate">
        <Link className="text-gray-700 hover:text-indigo-500" to={`/forms/${form.FormID}`}>
          <div className="max-w-[20vw] truncate">
            {i18n.language === 'en' && (titles.en || form.Title)}
            {i18n.language === 'fr' && (titles.fr || form.Title)}
            {i18n.language === 'de' && (titles.de || form.Title)}
          </div>
        </Link>
      </td>
      <td className="px-1.5 sm:px-6 py-4">{<FormStatus status={form.Status} />}</td>
      <td className="px-1.5 sm:px-6 py-4 text-right">
        <QuickAction status={form.Status} formID={form.FormID} />
      </td>
    </tr>
  );
};

export default FormRow;
