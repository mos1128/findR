import { useMemo, useState } from 'react';
import { Alert, Text, View } from 'react-native';
import {
  deleteCategory,
  listCategories,
  makeId,
  reorderCategories,
  upsertCategory,
  type Category,
} from '@findr/core';

import { Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { Button, EmptyState, Field, ListRow, Panel, Screen, SectionTitle } from '@/ui/kit';
import { useRuntime } from '@/platform/runtime';

const EMPTY = {
  id: '',
  name: '',
  emoji: '',
  description: '',
};

export default function CategoriesScreen() {
  const theme = useTheme();
  const { state: rt, refresh } = useRuntime();
  const [tick, setTick] = useState(0);
  const [form, setForm] = useState({ ...EMPTY });

  const categories = useMemo<Category[]>(() => (rt ? listCategories(rt.driver) : []), [rt, tick]);
  const reload = () => setTick((t) => t + 1);

  if (!rt) return <Screen />;

  const editing = form.id !== '';

  const onSave = () => {
    const name = form.name.trim();
    if (!name) {
      Alert.alert('分类要有名字');
      return;
    }
    try {
      upsertCategory(rt.driver, {
        id: form.id || makeId(),
        name,
        emoji: form.emoji.trim() || null,
        description: form.description.trim() || null,
        sort: editing
          ? (categories.find((c) => c.id === form.id)?.sort ?? categories.length)
          : categories.length,
        isPreset: editing ? (categories.find((c) => c.id === form.id)?.isPreset ?? false) : false,
      });
      setForm({ ...EMPTY });
      reload();
      void refresh();
    } catch (e) {
      Alert.alert('保存失败', `分类名不能重复（P1 的路由按名字匹配）。\n${e instanceof Error ? e.message : ''}`);
    }
  };

  const onDelete = (c: Category) => {
    Alert.alert(`删除「${c.name}」？`, '用到这个分类的卡片会变成「无分类」，卡片本身不会丢。', [
      { text: '取消', style: 'cancel' },
      {
        text: '删除',
        style: 'destructive',
        onPress: () => {
          const affected = deleteCategory(rt.driver, c.id, new Date());
          reload();
          void refresh();
          if (affected > 0) Alert.alert('已删除', `${affected} 张卡片改为无分类，可以逐张重新归类。`);
        },
      },
    ]);
  };

  const move = (index: number, delta: number) => {
    const ids = categories.map((c) => c.id);
    const j = index + delta;
    if (j < 0 || j >= ids.length) return;
    [ids[index], ids[j]] = [ids[j], ids[index]];
    reorderCategories(rt.driver, ids);
    reload();
  };

  return (
    <Screen>
      <Panel>
        <SectionTitle hint="AI 自动路由到这个池子，选不出才问你">分类池</SectionTitle>
        {categories.length === 0 ? (
          <EmptyState title="还没有分类" hint="预设分类被删光了吗？在下面新建一个。" />
        ) : (
          categories.map((c, i) => (
            <View key={c.id}>
              <ListRow
                title={`${c.emoji ?? ''}${c.name}`}
                subtitle={`${c.description ?? '没有识别描述'}${c.isPreset ? ' · 预设' : ''}`}
                onPress={() =>
                  setForm({
                    id: c.id,
                    name: c.name,
                    emoji: c.emoji ?? '',
                    description: c.description ?? '',
                  })
                }
                right={
                  <View style={{ flexDirection: 'row', gap: Spacing.two, alignItems: 'center' }}>
                    <Text onPress={() => move(i, -1)} style={{ color: theme.textMuted }}>
                      ↑
                    </Text>
                    <Text onPress={() => move(i, 1)} style={{ color: theme.textMuted }}>
                      ↓
                    </Text>
                    <Text onPress={() => onDelete(c)} style={{ color: theme.danger, fontSize: 12 }}>
                      删除
                    </Text>
                  </View>
                }
              />
            </View>
          ))
        )}
      </Panel>

      <Panel>
        <SectionTitle
          hint={editing ? '正在编辑已有分类' : '新建分类'}>
          {editing ? '编辑分类' : '新增分类'}
        </SectionTitle>
        <Field
          label="名称"
          value={form.name}
          onChangeText={(v) => setForm({ ...form, name: v })}
          placeholder="例如：装修记录"
        />
        <Field
          label="Emoji（可选）"
          value={form.emoji}
          onChangeText={(v) => setForm({ ...form, emoji: v })}
          placeholder="🔨"
        />
        <Field
          label="识别描述（给模型看）"
          value={form.description}
          onChangeText={(v) => setForm({ ...form, description: v })}
          placeholder="例如：装修期间临时堆放的物料"
          multiline
        />
        <Text style={{ color: theme.textMuted, fontSize: 11, lineHeight: 16 }}>
          分类只决定「这条记忆归到哪一类」。卡片长什么样（有没有位置、有没有步骤）由内容自己决定，
          不需要在这里配结构类型。
        </Text>
        <Button title={editing ? '保存修改' : '添加分类'} onPress={onSave} />
        {editing ? (
          <Button title="取消编辑" variant="ghost" compact onPress={() => setForm({ ...EMPTY })} />
        ) : null}
      </Panel>
    </Screen>
  );
}
