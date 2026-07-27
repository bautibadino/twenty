import { type I18n } from '@lingui/core';
import { Column, Container, Row } from '@react-email/components';
import { Link } from 'src/components/Link';
import { ShadowText } from 'src/components/ShadowText';
import { getAppName, isCustomBranded } from 'src/utils/branding';

const footerContainerStyle = {
  marginTop: '12px',
};

type FooterProps = {
  i18n: I18n;
};

/**
 * Footer propio del deploy. Los links de Twenty (sitio, GitHub, docs) y la
 * línea de la Public Benefit Corporation no aplican a una instancia
 * autohospedada: mandan al usuario a un proveedor que no es el suyo.
 *
 * APP_SOURCE_URL es opcional pero conviene definirla: la AGPL v3 (§13) pide
 * ofrecer el código fuente a quien usa el software por red, y este enlace es la
 * forma más simple de cumplirlo.
 */
const CustomFooter = ({ i18n }: FooterProps) => {
  const websiteUrl = process.env.APP_WEBSITE_URL?.trim();
  const sourceUrl = process.env.APP_SOURCE_URL?.trim();

  return (
    <Container style={footerContainerStyle}>
      {websiteUrl || sourceUrl ? (
        <Row>
          {websiteUrl ? (
            <Column>
              <ShadowText>
                <Link href={websiteUrl} value={i18n._('Website')} />
              </ShadowText>
            </Column>
          ) : (
            <></>
          )}
          {sourceUrl ? (
            <Column>
              <ShadowText>
                <Link href={sourceUrl} value={i18n._('Source code')} />
              </ShadowText>
            </Column>
          ) : (
            <></>
          )}
        </Row>
      ) : (
        <></>
      )}
      <ShadowText>
        <>{getAppName()}</>
      </ShadowText>
    </Container>
  );
};

export const Footer = ({ i18n }: FooterProps) => {
  if (isCustomBranded()) {
    return <CustomFooter i18n={i18n} />;
  }

  return (
    <Container style={footerContainerStyle}>
      <Row>
        <Column>
          <ShadowText>
            <Link
              href="https://twenty.com/"
              value={i18n._('Website')}
              aria-label={i18n._("Visit Twenty's website")}
            />
          </ShadowText>
        </Column>
        <Column>
          <ShadowText>
            <Link
              href="https://github.com/twentyhq/twenty"
              value={i18n._('Github')}
              aria-label={i18n._("Visit Twenty's GitHub repository")}
            />
          </ShadowText>
        </Column>
        <Column>
          <ShadowText>
            <Link
              href="https://docs.twenty.com/getting-started/introduction"
              value={i18n._('User guide')}
              aria-label={i18n._("Read Twenty's user guide")}
            />
          </ShadowText>
        </Column>
        <Column>
          <ShadowText>
            <Link
              href="https://docs.twenty.com/"
              value={i18n._('Developers')}
              aria-label={i18n._("Visit Twenty's developer documentation")}
            />
          </ShadowText>
        </Column>
      </Row>
      <ShadowText>
        <>
          {i18n._('Twenty.com, Public Benefit Corporation')}
          <br />
          {i18n._('San Francisco / Paris')}
        </>
      </ShadowText>
    </Container>
  );
};
