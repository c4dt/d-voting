import { expect, test } from '@playwright/test';
import { default as i18n } from 'i18next';
import { initI18n, setUp } from './shared';
import {
  SCIPER_ADMIN,
  SCIPER_OPERATOR,
  SCIPER_OTHER_ADMIN,
  SCIPER_OTHER_OPERATOR,
  mockPersonalInfo,
} from './mocks/api';
import { mockAdminList, mockOperatorList } from './mocks/evoting';

initI18n();

test.beforeEach(async ({ page }) => {
  await mockAdminList(page, [SCIPER_ADMIN, SCIPER_OTHER_ADMIN]);
  await mockOperatorList(page, [SCIPER_OPERATOR, SCIPER_OTHER_OPERATOR]);
  await mockPersonalInfo(page);
  await setUp(page, '/about');
});

test('Assert copyright notice is visible', async ({ page }) => {
  const footerCopyright = await page.getByTestId('footerCopyright');
  await expect(footerCopyright).toBeVisible();
  await expect(footerCopyright).toHaveText(
    `© ${new Date().getFullYear()} ${i18n.t('footerCopyright')} https://github.com/dedis/d-voting`
  );
});

test('Assert version information is visible', async ({ page }) => {
  const footerVersion = await page.getByTestId('footerVersion');
  await expect(footerVersion).toBeVisible();
  await expect(footerVersion).toHaveText(
    [
      `${i18n.t('footerVersion')} ${process.env.REACT_APP_VERSION || i18n.t('footerUnknown')}`,
      `${i18n.t('footerBuild')} ${process.env.REACT_APP_BUILD || i18n.t('footerUnknown')}`,
      `${i18n.t('footerBuildTime')} ${process.env.REACT_APP_BUILD_TIME || i18n.t('footerUnknown')}`,
    ].join(' - ')
  );
});
