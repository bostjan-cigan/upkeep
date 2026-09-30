import type { ReactNode } from 'react'
import { useApp } from '../../../app/hooks'
import { CheckCircleFill, Person } from '../../../app/icons'
import { Avatar, Row, Section, Sheet } from '../../../app/ui'
import { effectiveAssignee } from '../../../core/people'
import { assignOnce } from '../actions'
import { currentAssignee, type Task } from '../schedule'

/**
 * Hands just the next occurrence to someone else: "can you do it this time?". Who usually does it
 * is chosen in the task editor.
 */
export function HandOffSheet({ task, onClose }: { task: Task; onClose: () => void }) {
  const { household } = useApp()
  const people = household.people
  const usual = effectiveAssignee(task.assigneeUid, people)
  const current = effectiveAssignee(currentAssignee(task), people)
  const usualName = people.find((p) => p.uid === usual)?.name ?? 'everyone'

  const pick = (uid: string) => {
    if (uid === current) return onClose()
    // The usual person (even one who no longer exists) takes the hand-over back.
    void assignOnce(task, uid === usual ? task.assigneeUid : uid).then(onClose)
  }

  const check = (uid: string) => (uid === current ? <CheckCircleFill width={22} height={22} style={{ color: 'var(--tint)' }} /> : undefined)
  const row = (uid: string, name: string, leading: ReactNode) => (
    <Row
      key={uid || 'everyone'}
      inset={56}
      leading={leading}
      title={name}
      subtitle={uid === usual ? 'Usually' : undefined}
      trailing={check(uid)}
      onClick={() => pick(uid)}
    />
  )

  return (
    <Sheet title="This Time" onClose={onClose} auto>
      <Section title={task.title} footer={`Only this time. After it’s done, it goes back to ${usualName}.`}>
        {row('', 'Everyone', <span className="avatar everyone" style={{ width: 30, height: 30 }}><Person width={18} height={18} /></span>)}
        {people.map((p) => row(p.uid, p.name || 'Unnamed', <Avatar person={p} size={30} />))}
      </Section>
    </Sheet>
  )
}
