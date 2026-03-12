import json
import os
import time
import logging
from datetime import datetime

class DeactivationTracker:
    
    def __init__(self, storage_path="/srv/docker/edulution-mail/data", mark_count_threshold=3):
        self.storage_path = storage_path
        self.storage_file = os.path.join(storage_path, "deactivation_tracker.json")
        self.mark_count_threshold = mark_count_threshold
        self.data = {
            "domains": {},
            "mailboxes": {},
            "aliases": {},
            "filters": {},
            "alias_members": {}
        }
        self.load()
    
    def load(self):
        if os.path.exists(self.storage_file):
            try:
                with open(self.storage_file, 'r') as f:
                    loaded_data = json.load(f)

                # Merge loaded data with default structure to ensure all keys exist
                self.data.update(loaded_data)

                # Ensure all required keys exist (for backward compatibility)
                if "alias_members" not in self.data:
                    self.data["alias_members"] = {}
                    logging.info(f"  * Added missing 'alias_members' key to tracker")

                logging.info(f"  * Loaded deactivation tracker from {self.storage_file}")
            except Exception as e:
                logging.error(f"  * Failed to load deactivation tracker: {e}")
    
    def save(self):
        try:
            os.makedirs(self.storage_path, exist_ok=True)
            with open(self.storage_file, 'w') as f:
                json.dump(self.data, f, indent=2)
        except Exception as e:
            logging.error(f"  * Failed to save deactivation tracker: {e}")
    
    def markForDeactivation(self, item_type: str, item_id: str, grace_period_seconds: int):
        if item_type not in self.data:
            return False
        
        # Initialize or increment counter
        if item_id not in self.data[item_type]:
            self.data[item_type][item_id] = {
                "mark_count": 1,
                "first_marked_at": time.time(),
                "last_marked_at": time.time(),
                "deactivated": False
            }
            logging.info(f"  * First mark for {item_type} {item_id} (1/{self.mark_count_threshold})")
        else:
            # If already deactivated, don't increment counter
            if self.data[item_type][item_id].get("deactivated", False):
                return True
            
            current_count = self.data[item_type][item_id].get("mark_count", 0)
            if current_count < self.mark_count_threshold:
                self.data[item_type][item_id]["mark_count"] = current_count + 1
                self.data[item_type][item_id]["last_marked_at"] = time.time()
                logging.info(f"  * Mark {current_count + 1}/{self.mark_count_threshold} for {item_type} {item_id}")
            
            # On threshold mark, set for actual deactivation
            if self.data[item_type][item_id]["mark_count"] >= self.mark_count_threshold and not self.data[item_type][item_id].get("deactivated", False):
                delete_at = time.time() + grace_period_seconds
                delete_at_readable = datetime.fromtimestamp(delete_at).strftime('%Y-%m-%d %H:%M:%S')
                
                self.data[item_type][item_id]["deactivated"] = True
                self.data[item_type][item_id]["deactivated_at"] = time.time()
                self.data[item_type][item_id]["delete_at"] = delete_at
                self.data[item_type][item_id]["delete_at_readable"] = delete_at_readable
                
                logging.info(f"  * {item_type} {item_id} marked for deletion at {delete_at_readable} after {self.mark_count_threshold} marks")
        
        self.save()
        return self.data[item_type][item_id].get("mark_count", 0) >= self.mark_count_threshold
    
    def reactivate(self, item_type: str, item_id: str):
        if item_type in self.data and item_id in self.data[item_type]:
            # Reset counter instead of deleting completely
            self.data[item_type][item_id] = {
                "mark_count": 0,
                "deactivated": False
            }
            logging.info(f"  * Reset counter for {item_type} {item_id} (found in Keycloak again)")
            self.save()
            return True
        return False
    
    def getItemsToDelete(self, item_type: str) -> list:
        if item_type not in self.data:
            return []
        
        items_to_delete = []
        current_time = time.time()
        
        for item_id, info in self.data[item_type].items():
            if info.get("deactivated", False) and "delete_at" in info:
                if info["delete_at"] <= current_time:
                    items_to_delete.append(item_id)
        
        return items_to_delete
    
    def removeDeleted(self, item_type: str, item_id: str):
        if item_type in self.data and item_id in self.data[item_type]:
            del self.data[item_type][item_id]
            self.save()
    
    def isMarkedForDeactivation(self, item_type: str, item_id: str) -> bool:
        if item_type in self.data and item_id in self.data[item_type]:
            return self.data[item_type][item_id].get("deactivated", False)
        return False
    
    def getMarkCount(self, item_type: str, item_id: str) -> int:
        if item_type in self.data and item_id in self.data[item_type]:
            return self.data[item_type][item_id].get("mark_count", 0)
        return 0
    
    def getDeactivationInfo(self, item_type: str, item_id: str) -> dict:
        if self.isMarkedForDeactivation(item_type, item_id):
            return self.data[item_type][item_id]
        return None
    
    def formatDescriptionWithDeletionDate(self, original_description: str, item_type: str, item_id: str) -> str:
        info = self.getDeactivationInfo(item_type, item_id)
        if info and info.get("deactivated", False) and "delete_at_readable" in info:
            deletion_marker = f"[DEACTIVATED - DELETE AT: {info['delete_at_readable']}]"
            if original_description and deletion_marker not in original_description:
                return f"{deletion_marker} {original_description}"
            elif not original_description:
                return deletion_marker
        return original_description

    def trackAliasMemberChanges(self, alias_address: str, current_members: list, new_members: list) -> list:
        """
        Track changes to alias members with soft-delete logic.

        Args:
            alias_address: Email address of the alias/group
            current_members: Current list of member emails in Mailcow
            new_members: New list of member emails from Keycloak

        Returns:
            List of members that should actually be in the alias (including members still in grace period)
        """
        # Ensure alias_members key exists (backward compatibility)
        if "alias_members" not in self.data:
            self.data["alias_members"] = {}
            logging.info(f"  * Initialized missing 'alias_members' key in tracker")
            self.save()

        current_set = set(current_members) if current_members else set()
        new_set = set(new_members) if new_members else set()

        # Members to add (new members from Keycloak)
        members_to_add = new_set - current_set

        # Members that are in both (no change needed, reactivate if previously marked)
        members_still_present = current_set & new_set

        # Members that disappeared from Keycloak (mark for removal)
        members_missing = current_set - new_set

        # Reactivate members that are present again
        for member in members_still_present:
            member_key = f"{alias_address}:{member}"
            try:
                if "alias_members" in self.data and member_key in self.data["alias_members"]:
                    self.reactivate("alias_members", member_key)
            except Exception as e:
                logging.error(f"    -> Error reactivating member {member}: {e}")

        # Mark missing members for deactivation
        members_to_keep_in_grace = []
        for member in members_missing:
            member_key = f"{alias_address}:{member}"

            try:
                # Mark for deactivation (grace period is 0 for alias members, we only use mark count)
                reached_threshold = self.markForDeactivation("alias_members", member_key, 0)

                # If threshold not yet reached, keep the member in the alias
                if not reached_threshold:
                    members_to_keep_in_grace.append(member)
                    logging.info(f"    -> Keeping member {member} in alias {alias_address} during grace period ({self.getMarkCount('alias_members', member_key)}/{self.mark_count_threshold})")
                else:
                    logging.info(f"    -> Removing member {member} from alias {alias_address} after {self.mark_count_threshold} marks")
                    # Clean up from tracker after removal
                    self.removeDeleted("alias_members", member_key)
            except Exception as e:
                logging.error(f"    -> Error processing member {member} for deactivation: {e}")
                # On error, remove member immediately to avoid inconsistency
                logging.warning(f"    -> Removing member {member} immediately due to error")

        # New members to add (from Keycloak)
        for member in members_to_add:
            logging.info(f"    -> Adding new member {member} to alias {alias_address}")

        # Build final member list
        final_members = list(new_set) + members_to_keep_in_grace

        # Warning if group becomes empty after soft-delete
        if len(final_members) == 0 and len(current_members) > 0:
            logging.warning(f"    -> Group {alias_address} will become empty (all {len(current_members)} members removed after grace period)")

        return final_members