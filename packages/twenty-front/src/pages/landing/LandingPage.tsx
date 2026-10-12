import { styled } from '@linaria/react';
import { useLingui } from '@lingui/react/macro';
import { AppPath } from 'twenty-shared/types';
import { MainButton } from 'twenty-ui/components/input';
import { themeCssVariables } from 'twenty-ui/theme';

import { Logo } from '@/auth/components/Logo';
import { appNameState } from '@/client-config/states/appNameState';
import { UndecoratedLink } from '@/ui/navigation/link/components/UndecoratedLink/UndecoratedLink';
import { useAtomStateValue } from '@/ui/utilities/state/jotai/hooks/useAtomStateValue';

const StyledContainer = styled.div`
  align-items: center;
  display: flex;
  flex-direction: column;
  justify-content: center;
  min-height: 100dvh;
  padding: ${themeCssVariables.spacing[6]};
  width: 100%;
`;

const StyledHero = styled.div`
  align-items: center;
  display: flex;
  flex-direction: column;
  gap: ${themeCssVariables.spacing[4]};
  max-width: 480px;
  text-align: center;
`;

const StyledTitle = styled.h1`
  color: ${themeCssVariables.font.color.primary};
  font-size: ${themeCssVariables.font.size.xxl};
  font-weight: ${themeCssVariables.font.weight.semiBold};
  margin: 0;
`;

const StyledSubtitle = styled.p`
  color: ${themeCssVariables.font.color.secondary};
  font-size: ${themeCssVariables.font.size.md};
  line-height: 1.5;
  margin: 0;
`;

const StyledCtaContainer = styled.div`
  margin-top: ${themeCssVariables.spacing[4]};
  width: 200px;
`;

export const LandingPage = () => {
  const { t } = useLingui();
  const appName = useAtomStateValue(appNameState);

  return (
    <StyledContainer>
      <StyledHero>
        <Logo />
        <StyledTitle>{appName}</StyledTitle>
        <StyledSubtitle>
          {t`The CRM your whole team will love. Create your workspace in minutes and start organizing your business today.`}
        </StyledSubtitle>
        <StyledCtaContainer>
          <UndecoratedLink to={AppPath.SignInUp}>
            <MainButton title={t`Get started for free`} fullWidth />
          </UndecoratedLink>
        </StyledCtaContainer>
      </StyledHero>
    </StyledContainer>
  );
};
