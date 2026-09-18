import { useMemo, useState } from 'react';
import { Alert, Pressable, Text, View } from 'react-native';
import {
  deleteLocation,
  listLocations,
  makeId,
  refreshPathNames,
  renameLocation,
  upsertLocationNode,
  type LocationNode,
} from '@findr/core';

import { Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { Button, Chip, EmptyState, Field, ListRow, Panel, Screen, SectionTitle } from '@/ui/kit';
import { useRuntime } from '@/platform/runtime';

export default function LocationsScreen() {
  const theme = useTheme();
  const { state: rt, refresh } = useRuntime();
  const [tick, setTick] = useState(0);
  const [parentId, setParentId] = useState<string | null>(null);
  const [newName, setNewName] = useState('');
  const [renameId, setRenameId] = useState<string | null>(null);
  const [renameText, setRenameText] = useState('');

  const locations = useMemo<LocationNode[]>(
    () => (rt ? listLocations(rt.driver) : []),
    [rt, tick],
  );
  const byId = useMemo(() => new Map(locations.map((l) => [l.id, l])), [locations]);

  const reload = () => setTick((t) => t + 1);

  if (!rt) return <Screen />;

  const childrenOf = (pid: string | null) =>
    locations.filter((l) => l.parentId === pid).sort((a, b) => a.sort - b.sort);

  const addNode = () => {
    const name = newName.trim();
    if (!name) return;
    const siblings = childrenOf(parentId);
    try {
      upsertLocationNode(rt.driver, {
        id: makeId(),
        parentId,
        name,
        sort: siblings.length,
      });
      // 同名同父会被唯一索引忽略，这里明确告诉用户
      if (childrenOf(parentId).length === siblings.length) {
        Alert.alert('没加上', `「${name}」在这个层级下已经存在了。`);
      }
      setNewName('');
      reload();
    } catch (e) {
      Alert.alert('添加失败', e instanceof Error ? e.message : String(e));
    }
  };

  const onRename = (id: string) => {
    const name = renameText.trim();
    if (!name) return;
    renameLocation(rt.driver, id, name);
    // 位置改名后要刷新卡片的冗余串，否则按旧名字搜不到（M3 验收项）
    const changed = refreshPathNames(rt.driver, new Date());
    setRenameId(null);
    setRenameText('');
    reload();
    void refresh();
    if (changed > 0) Alert.alert('已同步', `${changed} 张卡片的位置串已更新。`);
  };

  const onDelete = (node: LocationNode) => {
    Alert.alert(`删除「${node.name}」？`, '有子节点或被卡片引用的位置不能删。', [
      { text: '取消', style: 'cancel' },
      {
        text: '删除',
        style: 'destructive',
        onPress: () => {
          const res = deleteLocation(rt.driver, node.id);
          if (!res.ok) {
            Alert.alert(
              '删不掉',
              res.reason === 'has_children'
                ? `它下面还有 ${res.count} 个子位置，先把子位置处理掉。`
                : `有 ${res.count} 张卡片用了这个位置。`,
            );
            return;
          }
          reload();
        },
      },
    ]);
  };

  const renderTree = (pid: string | null, depth: number): React.ReactNode =>
    childrenOf(pid).map((node) => (
      <View key={node.id}>
        {renameId === node.id ? (
          <View style={{ gap: Spacing.two, paddingVertical: Spacing.two }}>
            <Field label="新名称" value={renameText} onChangeText={setRenameText} autoFocus />
            <View style={{ flexDirection: 'row', gap: Spacing.two }}>
              <Button title="保存" compact onPress={() => onRename(node.id)} />
              <Button title="取消" variant="ghost" compact onPress={() => setRenameId(null)} />
            </View>
          </View>
        ) : (
          <Pressable
            onPress={() => {
              setParentId(node.id);
              setRenameText(node.name);
            }}
            onLongPress={() => {
              setRenameId(node.id);
              setRenameText(node.name);
            }}
            style={{ paddingVertical: 10, paddingLeft: depth * 16 }}>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: Spacing.two }}>
              <Text style={{ color: theme.text, fontSize: 15, flex: 1 }}>
                {depth === 0 ? '🏠 ' : '· '}
                {node.name}
              </Text>
              <Text style={{ color: theme.textMuted, fontSize: 11 }}>
                长按改名 ·{' '}
              </Text>
              <Pressable onPress={() => onDelete(node)}>
                <Text style={{ color: theme.danger, fontSize: 11 }}>删除</Text>
              </Pressable>
            </View>
          </Pressable>
        )}
        {renderTree(node.id, depth + 1)}
      </View>
    ));

  const pathLabel = (id: string | null): string => {
    const names: string[] = [];
    let cur = id ? byId.get(id) : undefined;
    while (cur) {
      names.unshift(cur.name);
      cur = cur.parentId ? byId.get(cur.parentId) : undefined;
    }
    return names.length > 0 ? names.join(' / ') : '顶层（房间）';
  };

  return (
    <Screen>
      <Panel>
        <SectionTitle hint="房间 → 家具 → 容器，层级用父子关系表达">位置树</SectionTitle>
        <Text style={{ color: theme.textMuted, fontSize: 11, lineHeight: 16 }}>
          位置会在解析卡片时自动长出来：说「次卧左侧床头柜」，没有就建、有就复用。这里是查看和整理的地方
          —— 改名、调层级、删除。位置名越规整，检索越准。
        </Text>
        {locations.length === 0 ? (
          <EmptyState title="还没有位置" hint="解析第一张带位置的卡片时会自动建，也可以现在手动加一个" />
        ) : (
          renderTree(null, 0)
        )}
      </Panel>

      <Panel>
        <SectionTitle hint={`将加到：${pathLabel(parentId)}`}>新增位置</SectionTitle>
        {parentId ? (
          <View style={{ flexDirection: 'row', gap: 6, flexWrap: 'wrap' }}>
            <Chip label="改加到顶层" onPress={() => setParentId(null)} />
            {byId.get(parentId) ? (
              <Chip
                label={`返回上一级：${byId.get(parentId)!.parentId ? pathLabel(byId.get(parentId)!.parentId) : '顶层'}`}
                onPress={() => setParentId(byId.get(parentId)!.parentId)}
              />
            ) : null}
          </View>
        ) : null}
        <Field
          label="名称"
          value={newName}
          onChangeText={setNewName}
          placeholder="例如：主卧 / 衣柜 / 顶层收纳盒"
        />
        <Button title="添加" onPress={addNode} />
        <Text style={{ color: theme.textMuted, fontSize: 11 }}>
          点上面的某个位置，就会把它设为新位置的父级。
        </Text>
      </Panel>

      <Panel>
        <SectionTitle>说明</SectionTitle>
        <ListRow
          title="自动新建"
          subtitle="解析卡片时，匹配不到的位置会自动建出来；卡片上会标出「新位置」，可以改选"
        />
        <ListRow title="重命名" subtitle="长按任一位置即可改名；改完会自动刷新卡片里的位置串" />
        <ListRow title="删除限制" subtitle="有子节点或仍被卡片引用的位置不允许删除" />
      </Panel>
    </Screen>
  );
}
