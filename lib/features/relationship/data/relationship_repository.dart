import '../../../core/supabase/supabase_config.dart';
import '../models/pair_relationship_model.dart';

class RelationshipRepository {
  final _client = SupabaseConfig.client;

  Future<PairRelationshipModel> fetchRelationship(String otherUserId) async {
    try {
      final rows = await _client.rpc('get_pair_relationship', params: {
        'p_other_user_id': otherUserId,
      });
      final list = rows as List;
      if (list.isEmpty) return PairRelationshipModel.empty;
      return PairRelationshipModel.fromJson(list.first as Map<String, dynamic>);
    } catch (_) {
      return PairRelationshipModel.empty;
    }
  }

  Future<List<PairAlbumEntryModel>> fetchAlbum(
      String myUserId, String otherUserId) async {
    final a = myUserId.compareTo(otherUserId) < 0 ? myUserId : otherUserId;
    final b = myUserId.compareTo(otherUserId) < 0 ? otherUserId : myUserId;
    try {
      final rows = await _client
          .from('pair_album_entries')
          .select('entry_id, milestone_type, occurred_at')
          .eq('user_a_id', a)
          .eq('user_b_id', b)
          .order('occurred_at', ascending: true);
      return (rows as List)
          .map((r) => PairAlbumEntryModel.fromJson(r as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}
