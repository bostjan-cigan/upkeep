// The maintenance module: items in the home → recurring tasks → completion logs.
// Importing it registers its kinds (homeItem, task, taskLog) with the core registry.
import { isMine } from '../../core/people'
import { currentAssignee, needsAttention, type Household } from './schedule'

export { buildHousehold } from './schedule'
export type { Household } from './schedule'

/** Mine tasks needing attention: the app badge and the Up Next tab badge. */
export function attentionCount(household: Household, myPersonUid: string, now: number): number {
  return household.tasks.filter((t) => needsAttention(t, now) && isMine(currentAssignee(t), myPersonUid, household.people)).length
}
