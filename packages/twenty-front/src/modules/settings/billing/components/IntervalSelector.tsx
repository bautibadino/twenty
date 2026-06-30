import { styled } from '@linaria/react';
import { useLingui } from '@lingui/react/macro';
import { CardPicker } from 'twenty-ui/input';
import { themeCssVariables } from 'twenty-ui/theme-constants';
import {
  BillingProductKey,
  SubscriptionInterval,
  type BillingPlanKey,
} from '~/generated-metadata/graphql';

import { usePlanByPlanKey } from '@/settings/billing/hooks/usePlanByPlanKey';

type IntervalSelectorProps = {
  selectedPlan: BillingPlanKey;
  interval: SubscriptionInterval;
  onIntervalChange: (interval: SubscriptionInterval) => void;
};

const StyledContainer = styled.div`
  display: flex;
  flex-direction: row;
  gap: ${themeCssVariables.spacing[2]};
  margin-bottom: ${themeCssVariables.spacing[4]};
  width: 100%;

  > * {
    flex: 1 1 0;
    min-width: 0;
  }
`;

const StyledIntervalLabel = styled.div`
  color: ${themeCssVariables.font.color.secondary};
  font-size: ${themeCssVariables.font.size.md};
  font-weight: ${themeCssVariables.font.weight.semiBold};
`;

const ORDERED_INTERVALS = [
  SubscriptionInterval.Month,
  SubscriptionInterval.Year,
];

export const IntervalSelector = ({
  selectedPlan,
  interval,
  onIntervalChange,
}: IntervalSelectorProps) => {
  const { t } = useLingui();
  const { getPlanByPlanKey } = usePlanByPlanKey();

  const plan = getPlanByPlanKey(selectedPlan);
  const baseProduct = plan.baseProducts.find(
    (product) =>
      product.metadata.productKey === BillingProductKey.BASE_PRODUCT,
  );

  const availableIntervals = ORDERED_INTERVALS.filter((candidateInterval) =>
    baseProduct && 'prices' in baseProduct
      ? baseProduct.prices?.some(
          (price) => price.recurringInterval === candidateInterval,
        )
      : false,
  );

  // Nothing to choose when the plan only offers a single billing interval.
  if (availableIntervals.length < 2) {
    return null;
  }

  const intervalLabel = (candidateInterval: SubscriptionInterval) =>
    candidateInterval === SubscriptionInterval.Year ? t`Yearly` : t`Monthly`;

  return (
    <StyledContainer>
      {availableIntervals.map((candidateInterval) => (
        <CardPicker
          checked={interval === candidateInterval}
          handleChange={() => onIntervalChange(candidateInterval)}
          key={candidateInterval}
        >
          <StyledIntervalLabel>
            {intervalLabel(candidateInterval)}
          </StyledIntervalLabel>
        </CardPicker>
      ))}
    </StyledContainer>
  );
};
