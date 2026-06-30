import { styled } from '@linaria/react';
import { isDefined } from 'twenty-shared/utils';
import { CardPicker } from 'twenty-ui/input';
import { themeCssVariables } from 'twenty-ui/theme-constants';
import {
  BillingProductKey,
  type BillingPlanKey,
  type SubscriptionInterval,
} from '~/generated-metadata/graphql';

import { SubscriptionPrice } from '@/settings/billing/components/SubscriptionPrice';
import { usePlans } from '@/settings/billing/hooks/usePlans';

type PlanSelectorProps = {
  selectedPlan: BillingPlanKey;
  interval: SubscriptionInterval;
  onPlanChange: (plan: BillingPlanKey) => void;
};

const StyledContainer = styled.div`
  display: flex;
  flex-direction: row;
  gap: ${themeCssVariables.spacing[2]};
  margin-bottom: ${themeCssVariables.spacing[4]};
  margin-top: ${themeCssVariables.spacing[4]};
  width: 100%;

  > * {
    flex: 1 1 0;
    min-width: 0;
  }
`;

const StyledPlanCard = styled.div`
  display: flex;
  flex-direction: column;
  gap: ${themeCssVariables.spacing[1]};
`;

const StyledPlanName = styled.div`
  color: ${themeCssVariables.font.color.secondary};
  font-size: ${themeCssVariables.font.size.md};
  font-weight: ${themeCssVariables.font.weight.semiBold};
`;

const StyledPlanPrice = styled.div`
  align-items: baseline;
  display: flex;
  gap: ${themeCssVariables.spacing[1]};
`;

export const PlanSelector = ({
  selectedPlan,
  interval,
  onPlanChange,
}: PlanSelectorProps) => {
  const { isPlansLoaded, listPlans } = usePlans();

  if (!isPlansLoaded) {
    return null;
  }

  const plans = listPlans();

  // Only show the selector when the operator has configured more than one plan
  // in Stripe; with a single plan there is nothing to choose.
  if (plans.length < 2) {
    return null;
  }

  return (
    <StyledContainer>
      {plans.map((plan) => {
        const baseProduct = plan.baseProducts.find(
          (product) =>
            product.metadata.productKey === BillingProductKey.BASE_PRODUCT,
        );

        const price =
          baseProduct && 'prices' in baseProduct
            ? baseProduct.prices?.find(
                (currentPrice) => currentPrice.recurringInterval === interval,
              )
            : undefined;

        return (
          <CardPicker
            checked={selectedPlan === plan.planKey}
            handleChange={() => onPlanChange(plan.planKey)}
            key={plan.planKey}
          >
            <StyledPlanCard>
              <StyledPlanName>{baseProduct?.name ?? plan.planKey}</StyledPlanName>
              {isDefined(price) && (
                <StyledPlanPrice>
                  <SubscriptionPrice
                    type={interval}
                    price={(price.unitAmount ?? 0) / 100}
                  />
                </StyledPlanPrice>
              )}
            </StyledPlanCard>
          </CardPicker>
        );
      })}
    </StyledContainer>
  );
};
